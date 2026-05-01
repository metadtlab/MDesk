use std::path::PathBuf;

#[cfg(target_os = "windows")]
fn main() {
    let mut candidates: Vec<PathBuf> = Vec::new();

    if let Ok(from_env) = std::env::var("MDESKMINI_ICON") {
        let trimmed = from_env.trim();
        if !trimmed.is_empty() {
            candidates.push(PathBuf::from(trimmed));
        }
    }

    // Requested default on this workstation.
    candidates.push(PathBuf::from(r"C:\Users\owner\Pictures\tray-icon.ico"));
    // Optional repo-local fallback.
    candidates.push(PathBuf::from("assets/tray-icon.ico"));

    let mut res = winres::WindowsResource::new();
    let icon_path = candidates.into_iter().find(|path| path.exists());
    if let Some(icon_path) = icon_path.as_ref() {
        res.set_icon(icon_path.to_string_lossy().as_ref());
    } else {
        println!("cargo:warning=mdeskmini icon file not found; compiling admin manifest only");
    }
    res.set_manifest(
        r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="requireAdministrator" uiAccess="false" />
      </requestedPrivileges>
    </security>
  </trustInfo>
</assembly>"#,
    );
    if let Err(err) = res.compile() {
        panic!("failed to compile windows resources: {err}");
    }
    if let Some(icon_path) = icon_path {
        println!("cargo:warning=mdeskmini icon={}", icon_path.display());
    }
}

#[cfg(not(target_os = "windows"))]
fn main() {}
