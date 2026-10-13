//! Compiled engine capabilities only: no configuration, GPU or network access.
use librustdesk::flutter_ffi;
use serde_json::{json, Value};
use std::io::{self, Write};
use std::path::Path;

pub fn report() -> Value {
    json!({
        "schema_version": 1,
        "product": "MDeskMini",
        "mini_version": env!("CARGO_PKG_VERSION"),
        "engine_version": librustdesk::VERSION,
        "architecture": std::env::consts::ARCH,
        "windows_version": super::os_support::windows_version(),
        "hwcodec_os_allowed": super::os_support::hardware_codec_allowed(),
        "hwcodec_min_windows_major": 10,
        "executable": std::env::current_exe().ok(),
        // Read the linked engine, not just Mini's own feature flags.
        "hwcodec": flutter_ffi::main_has_hwcodec().0,
        "vram": flutter_ffi::main_has_vram().0,
        "gpu_texture_render": flutter_ffi::main_has_gpu_texture_render().0,
        "device_support": "not_tested",
        "session_backend": "not_tested"
    })
}

pub fn write_report(output: Option<&Path>) -> io::Result<()> {
    let json = serde_json::to_string_pretty(&report())?;
    if let Some(path) = output {
        // Reject an existing output so stale reports cannot pass verification.
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(path)?;
        writeln!(file, "{json}")
    } else {
        writeln!(io::stdout().lock(), "{json}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn linked_engine_matches_selected_mini_features() {
        let data = report();
        assert_eq!(data["hwcodec"], cfg!(feature = "hwcodec"));
        assert_eq!(data["vram"], cfg!(feature = "vram"));
        assert_eq!(data["gpu_texture_render"], cfg!(feature = "vram"));
    }
}
