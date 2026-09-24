//! Best-effort cleanup of this portable executable only, never an installation.
use std::fs::{File, OpenOptions};
use std::io;
use std::os::windows::{fs::OpenOptionsExt, io::AsRawHandle, process::CommandExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use windows::Win32::Foundation::HANDLE;
use windows::Win32::Storage::FileSystem::{GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION};
use windows::Win32::System::Com::CoTaskMemFree;
use windows::Win32::System::SystemInformation::GetSystemDirectoryW;
use windows::Win32::UI::Shell::{FOLDERID_Downloads, SHGetKnownFolderPath, KF_FLAG_DEFAULT};

const CLEANUP_SCRIPT: &str = include_str!("self_cleanup.ps1");

pub struct CleanupTicket {
    executable: PathBuf,
    file_id: String,
    downloads: PathBuf,
    downloads_id: String,
}

fn file_identity(path: &Path, directory: bool) -> io::Result<String> {
    // OPEN_REPARSE_POINT: never follow a replaced final path component.
    let file: File = OpenOptions::new()
        .read(true)
        .share_mode(7)
        .custom_flags(0x00200000 | if directory { 0x02000000 } else { 0 })
        .open(path)?;
    let mut info = BY_HANDLE_FILE_INFORMATION::default();
    unsafe { GetFileInformationByHandle(HANDLE(file.as_raw_handle()), &mut info) }
        .map_err(io::Error::other)?;
    if info.dwFileAttributes & 0x400 != 0
        || (info.dwFileAttributes & 0x10 != 0) != directory
        || (info.nFileIndexHigh == 0 && info.nFileIndexLow == 0)
    {
        return Err(io::Error::other("Unsupported cleanup file identity"));
    }
    Ok(format!(
        "{:08X}-{:08X}-{:08X}-{:08X}-{:08X}",
        info.dwVolumeSerialNumber,
        info.nFileIndexHigh,
        info.nFileIndexLow,
        info.ftCreationTime.dwHighDateTime,
        info.ftCreationTime.dwLowDateTime
    ))
}

impl CleanupTicket {
    /// Capture before accepting sessions; a later replacement must not be deleted.
    pub fn capture() -> io::Result<Option<Self>> {
        let raw = unsafe { SHGetKnownFolderPath(&FOLDERID_Downloads, KF_FLAG_DEFAULT, None) }
            .map_err(io::Error::other)?;
        let downloads = unsafe { raw.to_string() };
        unsafe { CoTaskMemFree(Some(raw.0.cast())) };
        let downloads = PathBuf::from(downloads.map_err(io::Error::other)?).canonicalize()?;
        let executable = std::env::current_exe()?.canonicalize()?;
        Self::for_paths(executable, downloads)
    }

    fn for_paths(executable: PathBuf, downloads: PathBuf) -> io::Result<Option<Self>> {
        // Direct children only, not subdirectories or another folder called Downloads.
        if !executable.is_absolute()
            || !downloads.is_absolute()
            || !executable
                .extension()
                .and_then(|ext| ext.to_str())
                .is_some_and(|ext| ext.eq_ignore_ascii_case("exe"))
        {
            return Ok(None);
        }
        let Some(parent) = executable.parent() else {
            return Ok(None);
        };
        let downloads_id = file_identity(&downloads, true)?;
        if file_identity(parent, true)? != downloads_id {
            return Ok(None);
        }
        let file_id = file_identity(&executable, false)?;
        Ok(Some(Self {
            executable,
            file_id,
            downloads,
            downloads_id,
        }))
    }

    /// Called ONLY after the existing all-disconnected countdown has expired.
    /// The helper waits for this process to exit and gives file locks a bounded grace period.
    pub fn schedule(self) -> io::Result<()> {
        self.helper_command(std::process::id())?.spawn()?;
        Ok(())
    }

    fn helper_command(&self, parent_id: u32) -> io::Result<Command> {
        let mut system_dir = [0u16; 32768];
        let count = unsafe { GetSystemDirectoryW(Some(&mut system_dir)) } as usize;
        if count == 0 || count >= system_dir.len() {
            return Err(io::Error::other("Windows system directory unavailable"));
        }
        let powershell = PathBuf::from(String::from_utf16_lossy(&system_dir[..count]))
            .join("WindowsPowerShell/v1.0/powershell.exe");
        let mut command = Command::new(powershell);
        command
            .args([
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-WindowStyle",
                "Hidden",
                "-Command",
                CLEANUP_SCRIPT,
            ])
            // Paths are data, never interpolated into shell commands.
            .env("MDESK_MINI_CLEANUP_TARGET", &self.executable)
            .env("MDESK_MINI_CLEANUP_FILE_ID", &self.file_id)
            .env("MDESK_MINI_CLEANUP_DOWNLOADS", &self.downloads)
            .env("MDESK_MINI_CLEANUP_DOWNLOADS_ID", &self.downloads_id)
            .env("MDESK_MINI_CLEANUP_PID", parent_id.to_string())
            .current_dir(std::env::temp_dir())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .creation_flags(0x08000000); // CREATE_NO_WINDOW; no console flashing.
        Ok(command)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn production_command_waits_and_deletes_only_matching_dummy_file() {
        let root =
            std::env::temp_dir().join(format!("mini-cleanup-command-{}", std::process::id()));
        std::fs::create_dir(&root).unwrap();
        let target = root.join("Mini 한글 ' & [test].exe");
        let neighbor = root.join("keep.txt");
        std::fs::write(&target, b"dummy, never executed").unwrap();
        std::fs::write(&neighbor, b"keep").unwrap();
        let ticket =
            CleanupTicket::for_paths(target.canonicalize().unwrap(), root.canonicalize().unwrap())
                .unwrap()
                .unwrap();
        let helper_program = ticket.helper_command(1).unwrap().get_program().to_owned();
        let mut parent = Command::new(helper_program)
            .args([
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "Start-Sleep -Seconds 3",
            ])
            .creation_flags(0x08000000)
            .spawn()
            .unwrap();
        let mut helper = ticket.helper_command(parent.id()).unwrap().spawn().unwrap();
        std::thread::sleep(std::time::Duration::from_millis(700));
        assert!(parent.try_wait().unwrap().is_none());
        assert!(target.exists(), "must not delete before parent exits");
        parent.wait().unwrap();
        assert!(helper.wait().unwrap().success());
        assert!(
            !target.exists(),
            "production Rust-to-PowerShell identity and quoting must match"
        );
        assert!(neighbor.exists());
        std::fs::remove_file(neighbor).unwrap();
        std::fs::remove_dir(root).unwrap();
    }

    #[test]
    fn only_direct_downloads_executable_is_eligible() {
        let root = std::env::temp_dir().join(format!("mini-cleanup-scope-{}", std::process::id()));
        std::fs::create_dir(&root).unwrap();
        let downloads = root.join("Downloads");
        let subfolder = downloads.join("subfolder");
        let other = root.join("Other");
        std::fs::create_dir(&downloads).unwrap();
        std::fs::create_dir(&subfolder).unwrap();
        std::fs::create_dir(&other).unwrap();
        let paths = [
            downloads.join("Mini.exe"),
            subfolder.join("Mini.exe"),
            other.join("Mini.exe"),
            downloads.join("notes.txt"),
        ];
        for path in &paths {
            std::fs::write(path, b"dummy, never executed").unwrap();
        }
        assert!(
            CleanupTicket::for_paths(paths[0].clone(), downloads.clone())
                .unwrap()
                .is_some()
        );
        for path in &paths[1..] {
            assert!(CleanupTicket::for_paths(path.clone(), downloads.clone())
                .unwrap()
                .is_none());
        }
        for path in paths {
            std::fs::remove_file(path).unwrap();
        }
        for path in [subfolder, other, downloads, root] {
            std::fs::remove_dir(path).unwrap();
        }
    }
}
