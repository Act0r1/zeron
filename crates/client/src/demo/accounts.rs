//! Demo provider accounts (`ListAgentAccounts` & co.): who's signed in to
//! each agent CLI on a host, which login is in use, and plan usage windows —
//! seeded per device, mutated in memory by switch / remove.

use chrono::{Duration as Span, Utc};
use zeron_proto::{AgentAccount, AgentAccountsSnapshot, AgentAuthKind, AgentUsageWindow};

use super::fixtures;

fn window(label: &str, used: f32, resets_in: Span) -> AgentUsageWindow {
    AgentUsageWindow {
        label: label.into(),
        used_fraction: used,
        resets_at: Some(Utc::now() + resets_in),
    }
}

fn account(
    id: &str,
    harness: &str,
    email: Option<&str>,
    plan: Option<&str>,
    active: bool,
) -> AgentAccount {
    AgentAccount {
        id: id.into(),
        harness: serde_json::from_value(serde_json::json!(harness)).expect("demo harness id"),
        email: email.map(Into::into),
        plan_label: plan.map(Into::into),
        active,
        usage_windows: Vec::new(),
        usage_fetched_at: Some(crate::now_ms() - 3 * 60_000),
        usage_error: None,
        display_name: None,
        organization: None,
        auth_kind: Some(AgentAuthKind::Oauth),
        switchable: true,
        saved_at: Some(crate::now_ms() - 12 * 86_400_000),
        provider: None,
    }
}

/// The accounts a demo host starts with.
pub(crate) fn seed(device_id: &str) -> AgentAccountsSnapshot {
    let accounts = if device_id == fixtures::MAC {
        let mut work = account(
            "a1c0de0000000001",
            "claude-code",
            Some("wing@zeron.sh"),
            Some("Max 20×"),
            true,
        );
        work.usage_windows = vec![
            window("Session", 0.42, Span::minutes(133)),
            window("Week", 0.18, Span::days(3)),
        ];
        let mut personal = account(
            "a1c0de0000000002",
            "claude-code",
            Some("wing.lee@gmail.com"),
            Some("Pro"),
            false,
        );
        personal.usage_windows = vec![
            window("Session", 0.88, Span::minutes(47)),
            window("Week", 0.61, Span::days(5)),
        ];
        let mut codex = account(
            "c0de000000000001",
            "codex",
            Some("wing@zeron.sh"),
            Some("ChatGPT Plus"),
            true,
        );
        codex.usage_windows = vec![
            window("Session", 0.12, Span::hours(4)),
            window("Week", 0.64, Span::days(6)),
        ];
        let mut cursor = account(
            "c0501e0000000001",
            "cursor",
            Some("wing@zeron.sh"),
            Some("Pro"),
            true,
        );
        cursor.usage_windows = vec![window("Month", 0.97, Span::days(12))];
        let mut grok = account(
            "960c000000000001",
            "grok",
            Some("wing@zeron.sh"),
            Some("SuperGrok"),
            true,
        );
        grok.usage_error = Some("Rate limited by xAI — retrying in 2m".into());
        vec![work, personal, codex, cursor, grok]
    } else {
        let mut codex = account(
            "c0de000000000002",
            "codex",
            Some("ops@zeron.sh"),
            Some("ChatGPT Pro"),
            true,
        );
        codex.usage_windows = vec![
            window("Session", 0.05, Span::hours(3)),
            window("Week", 0.22, Span::days(4)),
        ];
        let mut key = account("a1c0de0000000003", "claude-code", None, None, true);
        key.display_name = Some("API key".into());
        key.auth_kind = Some(AgentAuthKind::ApiKey);
        key.usage_error = Some("API keys have no plan usage".into());
        vec![codex, key]
    };
    AgentAccountsSnapshot {
        accounts,
        warnings: Vec::new(),
    }
}

/// Make `id` the harness's (or its provider group's) account in use.
pub(crate) fn activate(snapshot: &mut AgentAccountsSnapshot, id: &str) -> bool {
    let Some(target) = snapshot.accounts.iter().find(|a| a.id == id).cloned() else {
        return false;
    };
    if !target.switchable {
        return false;
    }
    for a in &mut snapshot.accounts {
        if a.harness == target.harness && a.provider == target.provider {
            a.active = a.id == id;
        }
    }
    true
}

/// Remove `id` (the CLI is signed out when it was the one in use).
pub(crate) fn forget(snapshot: &mut AgentAccountsSnapshot, id: &str) -> bool {
    let before = snapshot.accounts.len();
    snapshot.accounts.retain(|a| a.id != id);
    snapshot.accounts.len() != before
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn switching_is_single_choice_per_harness() {
        let mut s = seed(fixtures::MAC);
        assert!(activate(&mut s, "a1c0de0000000002"));
        let claude: Vec<_> = s
            .accounts
            .iter()
            .filter(|a| a.id.starts_with("a1c0de"))
            .collect();
        assert!(!claude[0].active && claude[1].active);
        // Other harnesses keep theirs.
        assert!(
            s.accounts
                .iter()
                .find(|a| a.id == "c0de000000000001")
                .unwrap()
                .active
        );
        assert!(forget(&mut s, "a1c0de0000000002"));
        assert!(!s.accounts.iter().any(|a| a.id == "a1c0de0000000002"));
    }
}
