//! Bounded Windows log sampling. Grants/paths are fetched only from this host's configured API.
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    fs::{self, File, OpenOptions},
    io::{Read, Seek, SeekFrom},
    path::{Component, Path, PathBuf},
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};

pub const PREFIX: &str = "##MDESK_LOG_ANALYSIS_V1##";
static RUNNING: AtomicBool = AtomicBool::new(false);
const SAMPLE_LIMIT: usize = 262144;

#[derive(Deserialize)]
struct Grant {
    #[serde(rename = "jobId")]
    job_id: String,
    #[serde(rename = "collectionToken")]
    token: String,
}
#[derive(Deserialize)]
struct Target {
    #[serde(rename = "type")]
    kind: String,
    path: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Settings {
    targets: Vec<Target>,
    file_patterns: Vec<String>,
    recursive: bool,
    encoding: String,
    max_files: usize,
    max_total_mb: usize,
}
#[derive(Deserialize)]
struct Plan {
    settings: Settings,
}
#[derive(Serialize, Deserialize)]
struct Sample {
    path: String,
    text: String,
}
#[derive(Serialize, Default)]
#[serde(rename_all = "camelCase")]
struct Upload {
    files: Vec<Sample>,
    truncated: bool,
    error: String,
    warnings: Vec<CollectionWarning>,
    warnings_omitted: usize,
}
#[derive(Serialize)]
struct CollectionWarning {
    path: String,
    code: &'static str,
}
impl Upload {
    fn warn(&mut self, path: &Path, code: &'static str) {
        if self.warnings.len() < 100 {
            self.warnings.push(CollectionWarning {
                path: path.to_string_lossy().chars().take(2000).collect(),
                code,
            });
        } else {
            self.warnings_omitted += 1;
        }
    }
    fn io_warning(&mut self, path: &Path, error: &std::io::Error) {
        let code = match error.kind() {
            std::io::ErrorKind::NotFound => "not_found",
            std::io::ErrorKind::PermissionDenied => "permission_denied",
            std::io::ErrorKind::InvalidInput => "unsafe_path",
            _ if matches!(error.raw_os_error(), Some(32 | 33)) => "file_busy",
            _ => "read_failed",
        };
        self.warn(path, code);
    }
}
struct RunningGuard;
impl Drop for RunningGuard {
    fn drop(&mut self) {
        RUNNING.store(false, Ordering::Release);
    }
}

pub fn start(message: &str, api: String, peer: String, controller: String) {
    let Some(json) = message.strip_prefix(PREFIX).filter(|s| s.len() <= 512) else {
        return;
    };
    let Ok(grant) = serde_json::from_str::<Grant>(json) else {
        return;
    };
    if grant.job_id.len() != 36
        || grant.token.len() != 72
        || !grant
            .job_id
            .chars()
            .chain(grant.token.chars())
            .all(|c| c.is_ascii_hexdigit() || c == '-')
    {
        return;
    }
    let Ok(origin) = reqwest::Url::parse(&api) else {
        return;
    };
    let local = matches!(
        origin.host_str(),
        Some("localhost" | "127.0.0.1" | "[::1]" | "admin.localhost")
    );
    if origin.scheme() != "https" && !(origin.scheme() == "http" && local) {
        return;
    }
    if RUNNING
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Relaxed)
        .is_err()
    {
        return;
    }
    let spawn = std::thread::Builder::new()
        .name("log-analysis-collector".into())
        .spawn(move || {
            let _guard = RunningGuard;
            let _ = execute(grant, api, peer, controller);
        });
    if spawn.is_err() {
        RUNNING.store(false, Ordering::Release);
    }
}

fn execute(
    grant: Grant,
    api: String,
    peer: String,
    controller: String,
) -> Result<(), Box<dyn std::error::Error>> {
    let client = reqwest::blocking::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(90))
        .redirect(reqwest::redirect::Policy::none())
        .build()?;
    let url = format!(
        "{}/api/log-analysis/collect/{}",
        api.trim_end_matches('/'),
        grant.job_id
    );
    let headers = || {
        let mut headers = reqwest::header::HeaderMap::new();
        headers.insert("X-Collection-Token", grant.token.parse().unwrap());
        if let Ok(value) = peer.parse() {
            headers.insert("X-Peer-Id", value);
        }
        if let Ok(value) = controller.parse() {
            headers.insert("X-Controller-Id", value);
        }
        headers
    };
    let mut bytes = Vec::new();
    client
        .get(&url)
        .headers(headers())
        .send()?
        .error_for_status()?
        .take(65537)
        .read_to_end(&mut bytes)?;
    if bytes.len() > 65536 {
        return Err("collection plan too large".into());
    }
    let upload = match serde_json::from_slice::<Plan>(&bytes) {
        Ok(plan) => match collect(&plan.settings) {
            Ok(upload) => upload,
            Err(_) => Upload {
                error: "collection_failed".into(),
                ..Default::default()
            },
        },
        Err(_) => Upload {
            error: "invalid_plan".into(),
            ..Default::default()
        },
    };
    client
        .post(url)
        .headers(headers())
        .json(&upload)
        .send()?
        .error_for_status()?;
    Ok(())
}

fn safe_path(path: &Path) -> std::io::Result<()> {
    let text = path.to_string_lossy();
    if !path.is_absolute()
        || text.starts_with("\\\\")
        || text.starts_with("//")
        || text.contains(['*', '?'])
        || text.get(2..).map(|rest| rest.contains(':')).unwrap_or(true)
        || path
            .components()
            .any(|p| matches!(p, Component::ParentDir | Component::CurDir))
        || path.components().count() < 3
    {
        return Err(std::io::ErrorKind::InvalidInput.into());
    }
    for ancestor in path.ancestors() {
        if ancestor.as_os_str().is_empty() {
            continue;
        }
        let metadata = fs::symlink_metadata(ancestor)?;
        if is_link(&metadata) {
            return Err(std::io::ErrorKind::InvalidInput.into());
        }
    }
    Ok(())
}
fn is_link(metadata: &fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    metadata.file_attributes() & 0x400 != 0 || metadata.file_type().is_symlink()
}
fn matches_pattern(pattern: &str, name: &str) -> bool {
    let p: Vec<char> = pattern.to_lowercase().chars().collect();
    let n: Vec<char> = name.to_lowercase().chars().collect();
    let (mut i, mut j, mut star, mut mark) = (0, 0, None, 0);
    while j < n.len() {
        if i < p.len() && (p[i] == '?' || p[i] == n[j]) {
            i += 1;
            j += 1;
        } else if i < p.len() && p[i] == '*' {
            star = Some(i);
            i += 1;
            mark = j;
        } else if let Some(s) = star {
            i = s + 1;
            mark += 1;
            j = mark;
        } else {
            return false;
        }
    }
    while i < p.len() && p[i] == '*' {
        i += 1;
    }
    i == p.len()
}

fn collect(settings: &Settings) -> Result<Upload, Box<dyn std::error::Error>> {
    if settings.targets.is_empty()
        || settings.targets.len() > 20
        || settings.max_files == 0
        || settings.max_files > 100
        || settings.max_total_mb == 0
        || settings.max_total_mb > 100
        || settings.file_patterns.len() > 10
        || !matches!(
            settings.encoding.as_str(),
            "AUTO" | "UTF-8" | "MS949" | "UTF-16LE"
        )
    {
        return Err("invalid limits".into());
    }
    let mut upload = Upload::default();
    if settings.targets.iter().any(|t| t.kind == "windows_event") {
        if settings
            .targets
            .iter()
            .filter(|t| t.kind == "windows_event")
            .count()
            != 1
            || settings
                .targets
                .iter()
                .any(|t| t.kind == "windows_event" && t.path != "Application,System")
        {
            return Err("invalid event channels".into());
        }
        collect_windows_events(&mut upload);
    }
    let mut paths = Vec::new();
    let mut visited = 0;
    let deadline = Instant::now() + Duration::from_secs(20);
    for target in &settings.targets {
        if target.kind == "windows_event" {
            continue;
        }
        if target.path.len() > 2000 {
            return Err("invalid path".into());
        }
        let root = PathBuf::from(&target.path);
        if let Err(error) = safe_path(&root) {
            upload.io_warning(&root, &error);
            continue;
        }
        if target.kind == "file" {
            if !root.is_file() {
                upload.warn(&root, "not_file");
                continue;
            }
            paths.push(root);
        } else if target.kind == "folder" && root.is_dir() {
            let before = paths.len();
            let warnings_before = upload.warnings.len() + upload.warnings_omitted;
            let mut stack = vec![(root.clone(), 0)];
            while let Some((directory, depth)) = stack.pop() {
                if let Err(error) = safe_path(&directory) {
                    upload.io_warning(&directory, &error);
                    continue;
                }
                let entries = match fs::read_dir(&directory) {
                    Ok(entries) => entries,
                    Err(error) => {
                        upload.io_warning(&directory, &error);
                        continue;
                    }
                };
                for entry in entries {
                    visited += 1;
                    if visited > 10000 || Instant::now() > deadline {
                        upload.truncated = true;
                        break;
                    }
                    let entry = match entry {
                        Ok(entry) => entry,
                        Err(error) => {
                            upload.io_warning(&directory, &error);
                            continue;
                        }
                    };
                    let path = entry.path();
                    let metadata = match fs::symlink_metadata(&path) {
                        Ok(metadata) => metadata,
                        Err(error) => {
                            upload.io_warning(&path, &error);
                            continue;
                        }
                    };
                    if is_link(&metadata) {
                        upload.warn(&path, "unsafe_path");
                        continue;
                    }
                    if metadata.is_dir() && settings.recursive {
                        if depth < 16 {
                            stack.push((path, depth + 1));
                        } else {
                            upload.warn(&path, "depth_limit");
                        }
                    } else if metadata.is_file()
                        && settings
                            .file_patterns
                            .iter()
                            .any(|p| matches_pattern(p, &entry.file_name().to_string_lossy()))
                    {
                        paths.push(path);
                    }
                }
                if upload.truncated {
                    break;
                }
            }
            if paths.len() == before
                && !upload.truncated
                && upload.warnings.len() + upload.warnings_omitted == warnings_before
            {
                upload.warn(&root, "no_matches");
            }
        } else {
            upload.warn(&root, "not_folder");
            continue;
        }
        if visited > 10000 || Instant::now() > deadline {
            upload.truncated = true;
            break;
        }
    }
    // Most recently modified files first; individual samples are read from the tail.
    paths.sort_by_key(|p| std::cmp::Reverse(fs::metadata(p).and_then(|m| m.modified()).ok()));
    let mut seen = HashSet::new();
    let event_bytes: usize = upload.files.iter().map(|f| f.text.len()).sum();
    let mut remaining = SAMPLE_LIMIT
        .min(settings.max_total_mb * 1024 * 1024)
        .saturating_sub(event_bytes);
    for path in paths {
        if upload.files.len() >= settings.max_files || remaining == 0 {
            upload.truncated = true;
            break;
        }
        let result = (|| -> std::io::Result<Option<(Sample, usize, bool)>> {
            safe_path(&path)?;
            let canonical = fs::canonicalize(&path)?;
            if !seen.insert(canonical.to_string_lossy().to_lowercase()) {
                return Ok(None);
            }
            use std::os::windows::fs::OpenOptionsExt;
            let mut file = OpenOptions::new()
                .read(true)
                .custom_flags(0x00200000)
                .open(&path)?; // OPEN_REPARSE_POINT
            if is_link(&file.metadata()?) || final_path(&file)? != canonical {
                return Err(std::io::ErrorKind::InvalidInput.into());
            }
            let length = file.metadata()?.len();
            let mut head = Vec::new();
            (&mut file).take(4096).read_to_end(&mut head)?;
            let mut encoding = detect_encoding(&head);
            let take = remaining.min(65536) as u64;
            let mut offset = length.saturating_sub(take);
            if encoding == encoding_rs::UTF_16LE || encoding == encoding_rs::UTF_16BE {
                offset += offset % 2;
            }
            file.seek(SeekFrom::Start(offset))?;
            let mut bytes = Vec::new();
            file.take(take).read_to_end(&mut bytes)?;
            // An ASCII-only header cannot distinguish UTF-8 from Korean legacy logs.
            // Recheck complete sampled lines, excluding a possibly split leading character.
            if encoding == encoding_rs::UTF_8 && encoding_rs::Encoding::for_bom(&head).is_none() {
                let probe = if offset > 0 {
                    bytes
                        .iter()
                        .position(|b| *b == b'\n')
                        .map(|i| &bytes[i + 1..])
                        .unwrap_or(&[])
                } else {
                    bytes.as_slice()
                };
                if detect_encoding(probe) == encoding_rs::EUC_KR {
                    encoding = encoding_rs::EUC_KR;
                }
            }
            let (decoded, _, _) = encoding.decode(&bytes);
            let text = if offset > 0 {
                decoded.split_once('\n').map(|(_, s)| s).unwrap_or("")
            } else {
                &decoded
            };
            Ok(Some((
                Sample {
                    path: path.to_string_lossy().into(),
                    text: text.chars().take(remaining).collect(),
                },
                bytes.len(),
                offset > 0,
            )))
        })();
        match result {
            Ok(Some((sample, bytes, truncated))) => {
                remaining = remaining.saturating_sub(bytes);
                upload.truncated |= truncated;
                if sample.text.trim().is_empty() {
                    upload.warn(&path, "empty_sample");
                } else {
                    upload.files.push(sample);
                }
            }
            Ok(None) => (),
            Err(error) => upload.io_warning(&path, &error),
        }
    }
    Ok(upload)
}

fn collect_windows_events(upload: &mut Upload) {
    use std::{
        os::windows::process::CommandExt,
        process::{Command, Stdio},
        sync::mpsc,
    };
    #[derive(Deserialize)]
    struct EventWarning {
        path: String,
        code: String,
    }
    #[derive(Deserialize)]
    struct Events {
        files: Vec<Sample>,
        warnings: Vec<EventWarning>,
        truncated: bool,
    }
    let result = (|| -> Result<Events, Box<dyn std::error::Error>> {
        // Use the OS copy directly, never PATH or a user-configured executable/script.
        let root =
            PathBuf::from(std::env::var_os("SystemRoot").ok_or("missing Windows directory")?);
        if !root.is_absolute() {
            return Err("invalid Windows directory".into());
        }
        let mut child = Command::new(root.join("System32/WindowsPowerShell/v1.0/powershell.exe"))
            .args([
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                &include_str!("windows_event_analysis.ps1").replace(
                    "__MDESK_EVENT_POLICY_JSON__",
                    include_str!("windows_event_policy.json"),
                ),
            ])
            .creation_flags(0x08000000) // CREATE_NO_WINDOW; never flash a console over remote work.
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?;
        let stdout = child.stdout.take().ok_or("missing output")?;
        let (tx, rx) = mpsc::channel();
        let reader = std::thread::spawn(move || {
            let mut bytes = Vec::new();
            let read = stdout.take(1048577).read_to_end(&mut bytes);
            let _ = tx.send((read, bytes));
        });
        let output = rx.recv_timeout(Duration::from_secs(20));
        // Also terminate on oversized output; a full pipe must not hold a process open.
        if output
            .as_ref()
            .map(|(_, b)| b.len() > 1048576)
            .unwrap_or(true)
        {
            let _ = child.kill();
            let _ = child.wait();
            let _ = reader.join();
            return Err("event collection limit".into());
        }
        let status = child.wait()?;
        let _ = reader.join();
        if !status.success() {
            return Err("event collection failed".into());
        }
        let (read, bytes) = output?;
        read?;
        let events: Events = serde_json::from_slice(&bytes)?;
        if events.files.len() > 2
            || events.warnings.len() > 2
            || events.files.iter().map(|f| f.text.len()).sum::<usize>() > SAMPLE_LIMIT
            || events.files.iter().any(|f| {
                !matches!(
                    f.path.as_str(),
                    "windows-event://Application" | "windows-event://System"
                )
            })
        {
            return Err("invalid event output".into());
        }
        Ok(events)
    })();
    match result {
        Ok(events) => {
            upload.files.extend(events.files);
            upload.truncated |= events.truncated;
            for warning in events.warnings {
                let code = match warning.code.as_str() {
                    "no_matches" => "no_matches",
                    "permission_denied" => "permission_denied",
                    _ => "read_failed",
                };
                upload.warn(Path::new(&warning.path), code);
            }
        }
        Err(_) => upload.warn(
            Path::new("windows-event://Application,System"),
            "read_failed",
        ),
    }
}

fn detect_encoding(bytes: &[u8]) -> &'static encoding_rs::Encoding {
    if let Some((encoding, _)) = encoding_rs::Encoding::for_bom(bytes) {
        return encoding;
    }
    // Windows logs often use UTF-16 without a BOM; ASCII timestamp bytes expose the byte order.
    let pairs = bytes.len() / 2;
    if pairs >= 4 {
        let even_zero = bytes.chunks_exact(2).filter(|pair| pair[0] == 0).count();
        let odd_zero = bytes.chunks_exact(2).filter(|pair| pair[1] == 0).count();
        if odd_zero * 4 > pairs && even_zero * 10 < pairs {
            return encoding_rs::UTF_16LE;
        }
        if even_zero * 4 > pairs && odd_zero * 10 < pairs {
            return encoding_rs::UTF_16BE;
        }
    }
    match std::str::from_utf8(bytes) {
        Ok(_) => encoding_rs::UTF_8,
        // A bounded header sample may end in the middle of a UTF-8 character.
        Err(error) if error.error_len().is_none() => encoding_rs::UTF_8,
        Err(_) => encoding_rs::EUC_KR,
    }
}

fn final_path(file: &File) -> std::io::Result<PathBuf> {
    use std::os::windows::{ffi::OsStringExt, io::AsRawHandle};
    #[link(name = "kernel32")]
    extern "system" {
        fn GetFinalPathNameByHandleW(
            handle: *mut std::ffi::c_void,
            path: *mut u16,
            size: u32,
            flags: u32,
        ) -> u32;
    }
    let mut buffer = vec![0u16; 32768];
    let size = unsafe {
        GetFinalPathNameByHandleW(
            file.as_raw_handle(),
            buffer.as_mut_ptr(),
            buffer.len() as u32,
            0,
        )
    } as usize;
    if size == 0 || size >= buffer.len() {
        return Err(std::io::Error::last_os_error());
    }
    Ok(PathBuf::from(std::ffi::OsString::from_wide(
        &buffer[..size],
    )))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn grant_fetch_and_upload_use_bound_headers_and_real_file_sample() {
        use std::{io::Write, net::TcpListener};
        let root = std::env::temp_dir().join(format!("mdesk-log-http-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let path = root.join("today.log");
        fs::write(&path, "2026-09-20 11:00:00 synthetic failure\n").unwrap();
        let plan = serde_json::json!({"settings": {"targets": [{"type":"file", "path":path}],
            "filePatterns":[], "recursive":false, "encoding":"UTF-8", "maxFiles":20, "maxTotalMb":1}}).to_string();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            for index in 0..2 {
                let (mut stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(10)))
                    .unwrap();
                let mut header = Vec::new();
                while !header.ends_with(b"\r\n\r\n") {
                    let mut byte = [0];
                    stream.read_exact(&mut byte).unwrap();
                    header.push(byte[0]);
                    assert!(header.len() < 8192);
                }
                let header = String::from_utf8(header).unwrap().to_lowercase();
                assert!(header.contains("x-collection-token: test-grant"));
                assert!(header.contains("x-peer-id: peer-1"));
                assert!(header.contains("x-controller-id: controller-1"));
                if index == 1 {
                    let size: usize = header
                        .lines()
                        .find_map(|l| l.strip_prefix("content-length: "))
                        .unwrap()
                        .parse()
                        .unwrap();
                    let mut body = vec![0; size];
                    stream.read_exact(&mut body).unwrap();
                    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
                    assert!(json["files"][0]["text"]
                        .as_str()
                        .unwrap()
                        .contains("synthetic failure"));
                    assert_eq!(json["error"], "");
                }
                let body = if index == 0 {
                    plan.as_str()
                } else {
                    "{\"code\":1}"
                };
                write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body).unwrap();
            }
        });
        execute(
            Grant {
                job_id: "job-1".into(),
                token: "test-grant".into(),
            },
            format!("http://{}", address),
            "peer-1".into(),
            "controller-1".into(),
        )
        .unwrap();
        server.join().unwrap();
        fs::remove_file(path).unwrap();
        fs::remove_dir(root).unwrap();
    }
    #[test]
    fn filename_patterns_are_case_insensitive() {
        assert!(matches_pattern("*.LOG", "서비스.log"));
        assert!(matches_pattern("error-?.txt", "error-1.txt"));
        assert!(!matches_pattern("*.log", "error.txt"));
    }
    #[test]
    fn automatic_encoding_collects_utf8_ms949_and_utf16_logs() {
        let root = std::env::temp_dir().join(format!("mdesk-log-encoding-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let text = "2026-09-20 11:00:00 한글 오류 기록\n";
        let (cp949, _, _) = encoding_rs::EUC_KR.encode(text);
        let le: Vec<u8> = text.encode_utf16().flat_map(u16::to_le_bytes).collect();
        let be: Vec<u8> = text.encode_utf16().flat_map(u16::to_be_bytes).collect();
        for (name, bytes) in [
            ("utf8", text.as_bytes().to_vec()),
            ("cp949", cp949.to_vec()),
            ("utf16le", le.clone()),
            ("utf16be", be.clone()),
            ("bomle", [vec![0xff, 0xfe], le].concat()),
            ("bombe", [vec![0xfe, 0xff], be].concat()),
        ] {
            let path = root.join(format!("{}.log", name));
            fs::write(&path, bytes).unwrap();
            let settings = Settings {
                targets: vec![Target {
                    kind: "file".into(),
                    path: path.to_string_lossy().into(),
                }],
                file_patterns: vec![],
                recursive: false,
                encoding: "AUTO".into(),
                max_files: 20,
                max_total_mb: 1,
            };
            let upload = collect(&settings).unwrap();
            assert_eq!(upload.files[0].text, text, "{}", name);
            fs::remove_file(path).unwrap();
        }
        fs::remove_dir(root).unwrap();
    }
    #[test]
    fn ascii_header_does_not_hide_ms949_body() {
        let root = std::env::temp_dir().join(format!("mdesk-log-ascii-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let path = root.join("body.log");
        let text = "ASCII header\n".repeat(400) + "2026-09-20 11:00:00 한글 오류 기록\n";
        let (bytes, _, _) = encoding_rs::EUC_KR.encode(&text);
        fs::write(&path, bytes.as_ref()).unwrap();
        let settings = Settings {
            targets: vec![Target {
                kind: "file".into(),
                path: path.to_string_lossy().into(),
            }],
            file_patterns: vec![],
            recursive: false,
            encoding: "AUTO".into(),
            max_files: 20,
            max_total_mb: 1,
        };
        assert_eq!(collect(&settings).unwrap().files[0].text, text);
        fs::remove_file(path).unwrap();
        fs::remove_dir(root).unwrap();
    }
    #[test]
    fn missing_wrong_type_empty_and_locked_targets_do_not_discard_readable_logs() {
        use std::os::windows::fs::OpenOptionsExt;
        let root = std::env::temp_dir().join(format!("mdesk-log-partial-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let good = root.join("good.log");
        let locked = root.join("locked.log");
        let empty = root.join("empty.log");
        fs::write(&good, "2026-09-20 11:00:00 available\n").unwrap();
        fs::write(&locked, "locked content").unwrap();
        fs::write(&empty, "").unwrap();
        let lock = OpenOptions::new()
            .read(true)
            .share_mode(0)
            .open(&locked)
            .unwrap();
        let target = |kind: &str, path: &Path| Target {
            kind: kind.into(),
            path: path.to_string_lossy().into(),
        };
        let mut settings = Settings {
            targets: vec![
                target("folder", &root.join("missing")),
                target("file", &locked),
                target("folder", &good),
                target("file", &empty),
                target("file", &good),
            ],
            file_patterns: vec!["*.log".into()],
            recursive: false,
            encoding: "UTF-8".into(),
            max_files: 20,
            max_total_mb: 1,
        };
        let upload = collect(&settings).unwrap();
        assert!(upload.error.is_empty());
        assert_eq!(upload.files.len(), 1);
        assert!(upload.files[0].text.contains("available"));
        for code in ["not_found", "file_busy", "not_folder", "empty_sample"] {
            assert!(
                upload.warnings.iter().any(|w| w.code == code),
                "missing warning: {}",
                code
            );
        }
        settings.targets = vec![target("folder", &root.join("missing"))];
        let upload = collect(&settings).unwrap();
        assert!(upload.files.is_empty());
        assert_eq!(upload.warnings[0].code, "not_found");
        settings.targets = vec![target("folder", &root)];
        settings.file_patterns = vec!["*.not-a-log".into()];
        assert_eq!(collect(&settings).unwrap().warnings[0].code, "no_matches");
        drop(lock);
        for path in [good, locked, empty] {
            fs::remove_file(path).unwrap();
        }
        fs::remove_dir(root).unwrap();
    }
    #[test]
    fn warnings_are_bounded_and_unsafe_paths_remain_excluded() {
        let mut upload = Upload::default();
        for _ in 0..105 {
            upload.warn(Path::new("C:\\missing"), "not_found");
        }
        assert_eq!(upload.warnings.len(), 100);
        assert_eq!(upload.warnings_omitted, 5);
        let settings = Settings {
            targets: vec![Target {
                kind: "folder".into(),
                path: "C:\\".into(),
            }],
            file_patterns: vec!["*.log".into()],
            recursive: false,
            encoding: "UTF-8".into(),
            max_files: 20,
            max_total_mb: 1,
        };
        let upload = collect(&settings).unwrap();
        assert!(upload.files.is_empty());
        assert_eq!(upload.warnings[0].code, "unsafe_path");
    }
    #[test]
    fn unsafe_roots_are_rejected() {
        for p in [
            "C:\\",
            "relative\\logs",
            "\\\\host\\share",
            "C:\\logs\\..\\secret",
            "C:\\logs\\*.log",
        ] {
            assert!(safe_path(Path::new(p)).is_err());
        }
    }
    #[test]
    fn duplicate_files_are_sampled_once_and_explicit_files_ignore_patterns() {
        let root = std::env::temp_dir().join(format!("mdesk-log-test-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let path = root.join("sample.txt");
        fs::write(&path, "2026-09-20 11:00:00 test\n").unwrap();
        let settings = Settings {
            targets: vec![
                Target {
                    kind: "file".into(),
                    path: path.to_string_lossy().into(),
                },
                Target {
                    kind: "file".into(),
                    path: path.to_string_lossy().into(),
                },
            ],
            file_patterns: vec!["*.log".into()],
            recursive: false,
            encoding: "UTF-8".into(),
            max_files: 20,
            max_total_mb: 1,
        };
        let result = collect(&settings).unwrap();
        assert_eq!(result.files.len(), 1);
        fs::remove_file(path).unwrap();
        fs::remove_dir(root).unwrap();
    }
}
