//! Find this installation's child processes without relying on its display name.
use std::{fs, path::Path};

pub(super) fn role_processes(proc_dir: &Path, executable: &Path, role: &str) -> Vec<i32> {
    let mut pids = Vec::new();
    let Ok(entries) = fs::read_dir(proc_dir) else {
        return pids;
    };
    for entry in entries.flatten() {
        let Some(pid) = entry
            .file_name()
            .to_str()
            .and_then(|s| s.parse::<i32>().ok())
        else {
            continue;
        };
        if pid <= 1 || pid as u32 == std::process::id() {
            continue;
        }
        let Ok(peer_exe) = fs::read_link(entry.path().join("exe")) else {
            continue;
        };
        // An in-place package upgrade may leave a process using the unlinked
        // previous executable. Its installation path still identifies it.
        use std::os::unix::ffi::OsStrExt;
        let peer_path = peer_exe.as_os_str().as_bytes();
        let peer_path = peer_path.strip_suffix(b" (deleted)").unwrap_or(peer_path);
        if peer_path != executable.as_os_str().as_bytes() {
            continue;
        }
        let Ok(cmdline) = fs::read(entry.path().join("cmdline")) else {
            continue;
        };
        if cmdline.split(|b| *b == 0).nth(1) == Some(role.as_bytes()) {
            pids.push(pid);
        }
    }
    pids
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    #[test]
    fn package_name_does_not_control_session_cleanup() {
        let root = std::env::temp_dir().join(format!("mdesk-process-test-{}", std::process::id()));
        fs::create_dir(&root).unwrap();
        let executable = Path::new("/usr/share/rustdesk/rustdesk");
        let cases = [
            (
                101,
                "/usr/share/rustdesk/rustdesk",
                b"/usr/bin/rustdesk\0--server\0".as_slice(),
            ),
            (
                102,
                "/usr/share/rustdesk/rustdesk (deleted)",
                b"rustdesk\0--server\0".as_slice(),
            ),
            (
                103,
                "/opt/other/rustdesk",
                b"rustdesk\0--server\0".as_slice(),
            ),
            (
                104,
                "/usr/bin/sudo",
                b"sudo\0-u\0gdm\0rustdesk\0--server\0".as_slice(),
            ),
            (
                105,
                "/usr/share/rustdesk/rustdesk",
                b"rustdesk\0--service\0".as_slice(),
            ),
            (
                106,
                "/usr/share/rustdesk/rustdesk",
                b"rustdesk\0--server-extra\0".as_slice(),
            ),
            (
                107,
                "/usr/share/rustdesk/rustdesk",
                b"rustdesk\0--cm-no-ui\0".as_slice(),
            ),
            (
                108,
                "/usr/share/rustdesk/rustdesk",
                b"rustdesk\0\0".as_slice(),
            ),
        ];
        for (pid, exe, cmdline) in cases {
            let dir = root.join(pid.to_string());
            fs::create_dir(&dir).unwrap();
            symlink(exe, dir.join("exe")).unwrap();
            fs::write(dir.join("cmdline"), cmdline).unwrap();
        }
        let mut found = role_processes(&root, executable, "--server");
        found.sort();
        assert_eq!(found, [101, 102]);
        assert_eq!(role_processes(&root, executable, "--cm-no-ui"), [107]);
        fs::remove_dir_all(root).unwrap();
    }
}
