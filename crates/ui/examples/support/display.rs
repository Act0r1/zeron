pub fn require_isolated_display() -> std::io::Result<()> {
    #[cfg(target_os = "linux")]
    {
        let refused = || {
            std::io::Error::other(
                "GUI fixtures require a private Xvfb display. Use scripts/run-linux-fixture.sh; do not run them on the desktop display.",
            )
        };
        if std::env::var_os("WAYLAND_DISPLAY").is_some()
            || std::env::var_os("WAYLAND_SOCKET").is_some()
        {
            return Err(refused());
        }
        if std::env::var("GDK_BACKEND").as_deref() != Ok("x11") {
            return Err(refused());
        }
        let display = std::env::var("DISPLAY").map_err(|_| refused())?;
        let number = display
            .strip_prefix(':')
            .and_then(|value| value.split('.').next())
            .and_then(|value| value.parse::<u16>().ok())
            .ok_or_else(refused)?;
        let pid = std::fs::read_to_string(format!("/tmp/.X{number}-lock"))
            .map_err(|_| refused())?
            .trim()
            .parse::<u32>()
            .map_err(|_| refused())?;
        let server = std::fs::read_link(format!("/proc/{pid}/exe")).map_err(|_| refused())?;
        if server.file_name() != Some(std::ffi::OsStr::new("Xvfb")) {
            return Err(refused());
        }
    }
    Ok(())
}
