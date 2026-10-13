//! OS policy only: no saved settings, GPU probing or host initialization.

pub fn hardware_codec_allowed_on_version(version: Option<(u32, u32, u32)>) -> bool {
    version.is_some_and(|(major, _, _)| major >= 10)
}

#[cfg(windows)]
pub fn windows_version() -> Option<(u32, u32, u32)> {
    use std::sync::OnceLock;
    use windows::{
        core::{s, w},
        Win32::System::{
            LibraryLoader::{GetModuleHandleW, GetProcAddress},
            SystemInformation::OSVERSIONINFOW,
        },
    };
    static VERSION: OnceLock<Option<(u32, u32, u32)>> = OnceLock::new();
    *VERSION.get_or_init(|| unsafe {
        // Resolve from the already loaded system DLL. GetVersionEx and the
        // version helpers can report 6.2 without a recent compatibility manifest.
        let module = GetModuleHandleW(w!("ntdll.dll")).ok()?;
        let proc = GetProcAddress(module, s!("RtlGetVersion"))?;
        let query: unsafe extern "system" fn(*mut OSVERSIONINFOW) -> i32 =
            std::mem::transmute(proc);
        let mut version = OSVERSIONINFOW::default();
        version.dwOSVersionInfoSize = std::mem::size_of::<OSVERSIONINFOW>() as u32;
        (query(&mut version) == 0).then_some((
            version.dwMajorVersion,
            version.dwMinorVersion,
            version.dwBuildNumber,
        ))
    })
}

#[cfg(not(windows))]
pub fn windows_version() -> Option<(u32, u32, u32)> {
    None
}

pub fn hardware_codec_allowed() -> bool {
    !cfg!(windows) || hardware_codec_allowed_on_version(windows_version())
}

pub fn apply_codec_policy() {
    if !hardware_codec_allowed() {
        librustdesk::disable_hwcodec_for_process();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn old_or_unknown_windows_uses_software_codecs() {
        for version in [
            None,
            Some((6, 1, 7601)),
            Some((6, 2, 9200)),
            Some((6, 3, 9600)),
        ] {
            assert!(!hardware_codec_allowed_on_version(version));
        }
        for version in [Some((10, 0, 19045)), Some((10, 0, 22631)), Some((11, 0, 0))] {
            assert!(hardware_codec_allowed_on_version(version));
        }
    }

    #[test]
    fn process_block_also_stops_the_gpu_discovery_child() {
        librustdesk::disable_hwcodec_for_process();
        assert!(!librustdesk::hardware_codec_allowed_for_process());
        // Must return before IPC, signed client loading or driver discovery.
        super::super::run_hwcodec_discovery();
    }
}
