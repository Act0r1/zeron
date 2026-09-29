use std::{path::PathBuf, sync::Arc};

use codex_app_server_client::{EnvironmentManager, InProcessClientStartArgs};
use codex_config::{CloudConfigBundleLoader, LoaderOverrides};
use codex_core::config::{ConfigBuilder, ConfigOverrides};
use codex_feedback::CodexFeedback;
use codex_protocol::protocol::SessionSource;
use serde::Deserialize;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Options {
    pub home: PathBuf,
    pub fixture_base_url: Option<String>,
}

pub async fn start_args(options: &Options) -> std::io::Result<InProcessClientStartArgs> {
    if !options.home.is_absolute() {
        return Err(std::io::Error::other("Codex home must be absolute"));
    }
    std::fs::create_dir_all(options.home.join("context"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&options.home, std::fs::Permissions::from_mode(0o700))?;
    }
    // No executor is registered. All workspace access is through the three
    // dynamic mobile tools; Codex's metadata lives separately in its app home.
    let mut overrides: Vec<(String, toml::Value)> = vec![
        ("cli_auth_credentials_store".into(), "file".into()),
        ("approval_policy".into(), "never".into()),
        // Codex must describe the actual mobile tool contract, not its default read-only policy.
        ("sandbox_mode".into(), "workspace-write".into()),
        ("sandbox_workspace_write.writable_roots".into(), toml::Value::Array(vec!["/workspace".into()])),
        ("sandbox_workspace_write.exclude_tmpdir_env_var".into(), true.into()),
        ("sandbox_workspace_write.exclude_slash_tmp".into(), true.into()),
        ("web_search".into(), "disabled".into()),
        ("analytics.enabled".into(), false.into()),
        ("feedback.enabled".into(), false.into()),
        ("features.skip_host_skill_discovery".into(), true.into()),
    ];
    for feature in [
        "shell_tool",
        "apply_patch_freeform",
        "code_mode",
        "code_mode_host",
        "code_mode_prewarm",
        "code_mode_only",
        "multi_agent",
        "multi_agent_v2",
        "hooks",
        "plugin_hooks",
        "plugins",
        "remote_plugin",
        "recommended_plugins",
        "skill_search",
        "skill_mcp_dependency_install",
        "memories",
    ] {
        overrides.push((format!("features.{feature}"), false.into()));
    }
    if let Some(base_url) = &options.fixture_base_url {
        // The fixture endpoint is only for deterministic integration tests.
        if !base_url.starts_with("http://127.0.0.1:") {
            return Err(std::io::Error::other(
                "Fixture endpoint must use IPv4 loopback",
            ));
        }
        // Exercise model-driven code-mode-only routing, not just the feature defaults.
        let mut catalog: serde_json::Value = serde_json::from_str(include_str!(
            "../../../target/native-agent-spike/codex/codex-rs/models-manager/models.json"
        )).map_err(std::io::Error::other)?;
        let models = catalog["models"].as_array_mut().ok_or_else(|| std::io::Error::other("Invalid fixture catalog"))?;
        let mut model = models.first().cloned().ok_or_else(|| std::io::Error::other("Empty fixture catalog"))?;
        model["slug"] = "gpt-5.1-codex".into();
        model["tool_mode"] = "code_mode_only".into();
        model["supported_in_api"] = true.into();
        *models = vec![model];
        let catalog_path = options.home.join("fixture-models.json");
        std::fs::write(&catalog_path, serde_json::to_vec(&catalog).map_err(std::io::Error::other)?)?;
        overrides.push(("model_catalog_json".into(), catalog_path.to_string_lossy().into_owned().into()));
        overrides.extend([
            ("model_provider".into(), "mobile_fixture".into()),
            ("model".into(), "gpt-5.1-codex".into()),
            (
                "model_providers.mobile_fixture.name".into(),
                "Mobile test fixture".into(),
            ),
            (
                "model_providers.mobile_fixture.base_url".into(),
                base_url.clone().into(),
            ),
            (
                "model_providers.mobile_fixture.wire_api".into(),
                "responses".into(),
            ),
            (
                "model_providers.mobile_fixture.requires_openai_auth".into(),
                false.into(),
            ),
        ]);
    }
    let loader = LoaderOverrides {
        ignore_user_config: true,
        ignore_project_config: true,
        ignore_user_and_project_exec_policy_rules: true,
        ..Default::default()
    };
    let config = ConfigBuilder::default()
        .codex_home(options.home.clone())
        .cli_overrides(overrides.clone())
        .loader_overrides(loader.clone())
        .harness_overrides(ConfigOverrides {
            cwd: Some(options.home.join("context")),
            ..Default::default()
        })
        .build()
        .await?;
    let environments = EnvironmentManager::without_environments(config.http_client_factory());
    let state_db = codex_core::init_state_db(&config).await;
    Ok(InProcessClientStartArgs {
        arg0_paths: Default::default(),
        config: Arc::new(config),
        cli_overrides: overrides,
        loader_overrides: loader,
        strict_config: false,
        cloud_config_bundle: CloudConfigBundleLoader::default(),
        embedded_network_policy: Default::default(),
        feedback: CodexFeedback::new(),
        log_db: None,
        state_db,
        environment_manager: Arc::new(environments),
        config_warnings: vec![],
        session_source: SessionSource::Exec,
        enable_codex_api_key_env: false,
        client_name: "zeron_ios".into(),
        client_version: env!("CARGO_PKG_VERSION").into(),
        experimental_api: true,
        mcp_server_openai_form_elicitation: false,
        opt_out_notification_methods: vec![],
        channel_capacity: 128,
    })
}

pub const INSTRUCTIONS: &str = "You are running natively inside Zeron on iOS. Your project is in a writable, persistent /workspace filesystem, accessed ONLY through mobile_shell, mobile_read_file, and mobile_write_file. All three mobile tools are available independently of desktop execution environments and share the same files. Desktop shell or filesystem capability restrictions do not disable these mobile tools. Use mobile_write_file to create files and mobile_shell to list directories or edit files. Writes within /workspace are authorized; there is no additional enable-write-access step. Report a tool failure only after actually calling the tool. Completed writes persist even if a later command fails or is interrupted. Use these tools to inspect and edit the user's project. mobile_shell is a limited Bash interpreter, not an OS shell: it has no Node, npm, Cargo, Python, git, network, or native executable support. Each shell call begins in /workspace; use explicit paths. Shell commands have a 5 second limit. Do not claim to run unavailable builds or tests. The host cwd is private session metadata, not the user's project.";

pub fn tools() -> serde_json::Value {
    use serde_json::json;
    let function = |name: &str, description: &str, properties, required| {
        json!({
            "type": "function", "name": name, "description": description,
            "inputSchema": {"type":"object", "properties":properties, "required":required, "additionalProperties":false}
        })
    };
    json!([
        function(
            "mobile_shell",
            "Run a limited Bash command in /workspace. Supports pipes, grep, rg, sed, awk, jq and file operations. No native executables or networking.",
            json!({"command":{"type":"string"}}),
            json!(["command"])
        ),
        function(
            "mobile_read_file",
            "Read a UTF-8 file from the shared virtual workspace. Use an absolute /workspace/ path.",
            json!({"path":{"type":"string"}}),
            json!(["path"])
        ),
        function(
            "mobile_write_file",
            "Write a UTF-8 file in the shared virtual workspace. Use an absolute /workspace/ path.",
            json!({"path":{"type":"string"},"content":{"type":"string"}}),
            json!(["path", "content"])
        )
    ])
}
