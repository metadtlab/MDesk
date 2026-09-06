//! Persistent, bounded connection diagnostics. Deliberately std-only so the
//! portable launcher can record time before the main application starts.
//! Never pass credentials, request/response bodies, URLs or raw error messages.
use std::{
    fs::{self, File, OpenOptions},
    io::{self, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        mpsc, OnceLock,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const MAX_BYTES: u64 = 2 * 1024 * 1024;
const RETENTION: Duration = Duration::from_secs(7 * 24 * 60 * 60);
static LOGGER: OnceLock<Option<Logger>> = OnceLock::new();
static DROPPED: AtomicU64 = AtomicU64::new(0);

struct Logger {
    sender: mpsc::SyncSender<Command>,
    started: Instant,
    run: String,
}
enum Command {
    Line(String),
    Flush(mpsc::Sender<()>),
}

pub fn directory() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    base.join("MDesk").join("diagnostics")
}

fn epoch_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

// Escape controls as well as quotes; one event must always occupy one line.
fn quoted(value: &str) -> String {
    let mut out = String::from("\"");
    for c in value.chars().take(256) {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if c <= '\u{1f}' => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Only numeric peer IDs and UUID-like correlation IDs are retained. In
/// particular, an ID of the form id@server?key=... must not expose its suffix.
pub fn correlation(value: &str) -> String {
    value
        .split(['@', '?', '/'])
        .next()
        .unwrap_or_default()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-')
        .take(80)
        .collect()
}

fn endpoint(value: &str) -> String {
    value
        .split("://")
        .last()
        .unwrap_or_default()
        .split(['/', '?', '#'])
        .next()
        .unwrap_or_default()
        .rsplit('@')
        .next()
        .unwrap_or_default()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || ".-:[]".contains(*c))
        .take(160)
        .collect()
}

/// Classify without persisting arbitrary errors (which may include URLs/tokens).
pub fn error_kind(message: &str) -> &'static str {
    let text = message.to_ascii_lowercase();
    if text.contains("timeout") || text.contains("timed out") {
        "timeout"
    } else if text.contains("offline") {
        "offline"
    } else if text.contains("resolve") || text.contains("dns") {
        "dns"
    } else if text.contains("refused") {
        "refused"
    } else if text.contains("reset") || text.contains("closed") {
        "disconnected"
    } else if text.contains("password") || text.contains("permission") || text.contains("denied") {
        "authentication_or_permission"
    } else if text.contains("key") || text.contains("handshake") {
        "handshake"
    } else {
        "other"
    }
}

fn initialize() -> Option<Logger> {
    let dir = directory();
    if fs::create_dir_all(&dir).is_err() {
        eprintln!("MDesk connection diagnostics: directory unavailable");
        return None;
    }
    let run = format!("{}-{}", epoch_ms(), std::process::id());
    let path = dir.join(format!("mdesk-diag-{run}.jsonl"));
    let file = match OpenOptions::new().create(true).append(true).open(&path) {
        Ok(file) => file,
        Err(_) => {
            eprintln!("MDesk connection diagnostics: file unavailable");
            return None;
        }
    };
    let (sender, receiver) = mpsc::sync_channel(512);
    if std::thread::Builder::new()
        .name("connection-diagnostics".into())
        .spawn(move || {
            prune(&dir);
            let mut writer = RotatingWriter {
                path,
                file: Some(file),
                bytes: 0,
                limit: MAX_BYTES,
            };
            let mut reported_error = false;
            while let Ok(command) = receiver.recv() {
                let result = match command {
                    Command::Line(line) => writer.line(&line),
                    Command::Flush(reply) => {
                        let result = writer.file.as_mut().map(|f| f.flush()).unwrap_or(Ok(()));
                        let _ = reply.send(());
                        result
                    }
                };
                if result.is_err() && !reported_error {
                    reported_error = true;
                    eprintln!("MDesk connection diagnostics: write failed");
                }
            }
        })
        .is_err()
    {
        return None;
    }
    Some(Logger {
        sender,
        started: Instant::now(),
        run,
    })
}

fn prune(dir: &Path) {
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with("mdesk-diag-") && name.ends_with(".jsonl") {
                if let Ok(metadata) = entry.metadata() {
                    if metadata.is_file()
                        && metadata
                            .modified()
                            .ok()
                            .and_then(|t| t.elapsed().ok())
                            .map(|age| age > RETENTION)
                            .unwrap_or(false)
                    {
                        let _ = fs::remove_file(entry.path());
                    }
                }
            }
        }
    }
}

struct RotatingWriter {
    path: PathBuf,
    file: Option<File>,
    bytes: u64,
    limit: u64,
}
impl RotatingWriter {
    fn backup(&self, n: usize) -> PathBuf {
        self.path.with_extension(format!("{n}.jsonl"))
    }
    fn line(&mut self, line: &str) -> io::Result<()> {
        if self.bytes + line.len() as u64 + 1 > self.limit {
            self.file.take(); // Close before rename on Windows.
            let _ = fs::remove_file(self.backup(2));
            if self.backup(1).exists() {
                fs::rename(self.backup(1), self.backup(2))?;
            }
            fs::rename(&self.path, self.backup(1))?;
            self.bytes = 0;
        }
        if self.file.is_none() {
            self.file = Some(
                OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&self.path)?,
            );
        }
        let file = self.file.as_mut().unwrap();
        writeln!(file, "{line}")?;
        self.bytes += line.len() as u64 + 1;
        Ok(())
    }
}

pub fn event(role: &str, session: &str, stage: &str, fields: &[(&str, &str)]) {
    let Some(logger) = LOGGER.get_or_init(initialize).as_ref() else {
        return;
    };
    let dropped = DROPPED.swap(0, Ordering::Relaxed);
    let mut line = format!(
        "{{\"schema\":1,\"epoch_ms\":{},\"process_ms\":{},\"pid\":{},\"run\":{},\"version\":{},\"role\":{},\"session\":{},\"stage\":{},\"dropped\":{}",
        epoch_ms(), logger.started.elapsed().as_millis(), std::process::id(),
        quoted(&logger.run), quoted(option_env!("CARGO_PKG_VERSION").unwrap_or("test")),
        quoted(role), quoted(&correlation(session)), quoted(stage), dropped
    );
    // Fixed vocabulary prevents accidentally persisting a token/body via a new caller.
    for (key, value) in fields.iter().take(24) {
        if matches!(
            *key,
            "peer"
                | "duration_ms"
                | "result"
                | "force_relay"
                | "attempt"
                | "route"
                | "registered"
                | "key_confirmed"
                | "host_key_confirmed"
                | "session_id"
                | "source_id"
                | "relay_uuid"
                | "status"
                | "elapsed_ms"
                | "bytes_per_sec"
                | "fps"
                | "decode_fps"
                | "queue"
                | "codec"
                | "round"
                | "display"
                | "delay_ms"
                | "bitrate"
                | "width"
                | "height"
                | "build"
                | "ready"
                | "installed"
                | "files"
                | "reason"
                | "authorized"
                | "server"
                | "local_id"
                | "local_port"
                | "progress"
                | "timeout_ms"
        ) {
            let value = if matches!(*key, "peer" | "source_id" | "relay_uuid") {
                correlation(value)
            } else if *key == "server" {
                endpoint(value)
            } else {
                value.to_string()
            };
            line.push_str(&format!(",{}:{}", quoted(key), quoted(&value)));
        }
    }
    line.push('}');
    if logger.sender.try_send(Command::Line(line)).is_err() {
        DROPPED.fetch_add(dropped + 1, Ordering::Relaxed);
    }
}

/// Drain queued milestones on normal exit. Never delays shutdown beyond 1s.
pub fn flush() {
    if let Some(Some(logger)) = LOGGER.get() {
        let (tx, rx) = mpsc::channel();
        if logger.sender.try_send(Command::Flush(tx)).is_ok() {
            let _ = rx.recv_timeout(Duration::from_secs(1));
        }
    }
}

/// Begin/end pair also identifies early returns, errors and cancelled futures.
pub struct Span {
    role: &'static str,
    session: String,
    stage: &'static str,
    start: Instant,
    result: &'static str,
}
impl Span {
    pub fn new(role: &'static str, session: &str, stage: &'static str) -> Self {
        event(role, session, &format!("{stage}.begin"), &[]);
        Self {
            role,
            session: correlation(session),
            stage,
            start: Instant::now(),
            result: "incomplete",
        }
    }
    pub fn success(&mut self) {
        self.result = "ok";
    }
    pub fn lifetime(role: &'static str, session: &str, stage: &'static str) -> Self {
        let mut span = Self::new(role, session, stage);
        span.result = "ended";
        span
    }
}
impl Drop for Span {
    fn drop(&mut self) {
        event(
            self.role,
            &self.session,
            &format!("{}.end", self.stage),
            &[
                ("duration_ms", &self.start.elapsed().as_millis().to_string()),
                ("result", self.result),
            ],
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn escapes_json_controls_and_limits_values() {
        assert_eq!(quoted("a\n\"\\\t"), "\"a\\u000a\\\"\\\\\\u0009\"");
        assert_eq!(quoted(&"x".repeat(300)).len(), 258);
        assert_eq!(correlation("123/r@server?key=SECRET"), "123");
        assert_eq!(
            endpoint("wss://user:SECRET@relay.example:443/path?token=SECRET"),
            "relay.example:443"
        );
    }
    #[test]
    fn rotation_preserves_recent_events_and_bounds_files() {
        let dir = std::env::temp_dir().join(format!(
            "mdesk-diag-test-{}-{}",
            epoch_ms(),
            std::process::id()
        ));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("test.jsonl");
        let file = File::create(&path).unwrap();
        let mut writer = RotatingWriter {
            path,
            file: Some(file),
            bytes: 0,
            limit: 8,
        };
        for n in 0..5 {
            writer.line(&format!("line{n}")).unwrap();
        }
        assert_eq!(fs::read_to_string(&writer.path).unwrap(), "line4\n");
        assert_eq!(fs::read_to_string(writer.backup(1)).unwrap(), "line3\n");
        assert_eq!(fs::read_to_string(writer.backup(2)).unwrap(), "line2\n");
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 3);
        drop(writer);
        fs::remove_dir_all(dir).unwrap();
    }
}
