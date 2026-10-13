//! Opt-in, sampled wall-time diagnostics for performance investigation.
//! No log directory, worker thread, timer or channel is created when disabled.
//! API durations are CPU wall time, not GPU completion or actual screen presentation.
use std::{
    collections::BTreeMap,
    fs::OpenOptions,
    io::{BufWriter, Write},
    path::PathBuf,
    sync::{atomic::{AtomicU64, Ordering}, mpsc, OnceLock},
    time::{Duration, Instant},
};

const WINDOW: Duration = Duration::from_secs(5);
const SAMPLE_EVERY: u64 = 30;
const MAX_BYTES: u64 = 8 * 1024 * 1024;
static TRACE: OnceLock<Option<Trace>> = OnceLock::new();
static DROPPED: AtomicU64 = AtomicU64::new(0);
static COUNTERS: [AtomicU64; 7] = [AtomicU64::new(0), AtomicU64::new(0),
    AtomicU64::new(0), AtomicU64::new(0), AtomicU64::new(0),
    AtomicU64::new(0), AtomicU64::new(0)];

#[derive(Clone, Copy)]
pub enum Stage { Capture, Convert, Encode, Record, SendEnqueue, DecodeConvert, VideoCallback }
impl Stage {
    fn name(self) -> &'static str {
        match self {
            Self::Capture => "capture_api", Self::Convert => "convert_api",
            Self::Encode => "encode_api", Self::Record => "record_lock_write",
            Self::SendEnqueue => "send_enqueue", Self::DecodeConvert => "decode_convert_api",
            Self::VideoCallback => "video_callback_api",
        }
    }
}
struct Trace { tx: mpsc::SyncSender<Command> }
enum Command {
    Sample(&'static str, usize, u64),
    Runtime(usize, String, bool, bool),
}
pub struct Probe { start: Option<Instant>, stage: &'static str, display: usize }

#[derive(Default)]
struct Stats { count: u64, sum: u128, max: u64, bins: BTreeMap<u64, u64> }
impl Stats {
    fn add(&mut self, us: u64) {
        self.count += 1;
        self.sum += us as u128;
        self.max = self.max.max(us);
        // Fixed logarithmic buckets. Quantiles are explicitly UPPER BOUNDS.
        let upper = if us == 0 { 0 } else { us.checked_next_power_of_two().unwrap_or(u64::MAX) };
        *self.bins.entry(upper).or_default() += 1;
    }
    fn percentile_upper(&self, percent: u64) -> u64 {
        let rank = (self.count * percent + 99) / 100;
        let mut count = 0;
        for (upper, n) in &self.bins {
            count += n;
            if count >= rank { return *upper; }
        }
        0
    }
}

fn initialize() -> Option<Trace> {
    if std::env::var("MDESK_PERF_TRACE").as_deref() != Ok("1") { return None; }
    let path = PathBuf::from(std::env::var_os("MDESK_PERF_LOG")?);
    if !path.is_absolute() { return None; }
    // Create a NEW file only. Do not truncate previous experiments or fall back
    // to an operational config/log path. Prepare the parent in the trial runner.
    let file = OpenOptions::new().write(true).create_new(true).open(path).ok()?;
    let (tx, rx) = mpsc::sync_channel(1024);
    std::thread::Builder::new().name("trial-performance".into()).spawn(move || {
        let mut writer = BufWriter::new(file);
        let start = Instant::now();
        let mut deadline = start + WINDOW;
        let mut stats: BTreeMap<(&'static str, usize), Stats> = BTreeMap::new();
        let mut bytes = 0u64;
        loop {
            match rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
                Ok(Command::Sample(stage, display, us)) => {
                    if stats.len() < 128 || stats.contains_key(&(stage, display)) {
                        stats.entry((stage, display)).or_default().add(us);
                    } else { DROPPED.fetch_add(1, Ordering::Relaxed); }
                }
                Ok(Command::Runtime(display, payload, recording, use_i444)) => {
                    let line = format!("{{\"kind\":\"runtime_path\",\"mono_ms\":{},\"display\":{},\"encoder\":{},\"incoming_recording\":{},\"use_i444\":{}}}\n", start.elapsed().as_millis(), display, payload, recording, use_i444);
                    if !write_bounded(&mut writer, &mut bytes, &line) { break; }
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
                Err(mpsc::RecvTimeoutError::Timeout) => {},
            }
            // Check the clock even when the channel stays busy.
            if Instant::now() >= deadline {
                for ((stage, display), s) in std::mem::take(&mut stats) {
                    let line = format!("{{\"kind\":\"stage_summary\",\"mono_ms\":{},\"stage\":\"{}\",\"display\":{},\"sample_every\":{},\"samples\":{},\"mean_us\":{},\"max_us\":{},\"p95_upper_us\":{},\"dropped_total\":{}}}\n", start.elapsed().as_millis(), stage, display, SAMPLE_EVERY, s.count, s.sum / s.count as u128, s.max, s.percentile_upper(95), DROPPED.load(Ordering::Relaxed));
                    if !write_bounded(&mut writer, &mut bytes, &line) { return; }
                }
                if writer.flush().is_err() { break; }
                deadline = Instant::now() + WINDOW;
            }
        }
    }).ok()?;
    Some(Trace { tx })
}

fn write_bounded(writer: &mut impl Write, bytes: &mut u64, line: &str) -> bool {
    if *bytes + line.len() as u64 > MAX_BYTES { return false; }
    if writer.write_all(line.as_bytes()).is_err() { return false; }
    *bytes += line.len() as u64;
    true
}

pub fn start(stage: Stage, display: usize) -> Probe {
    let enabled = TRACE.get_or_init(initialize).is_some();
    let sampled = enabled && COUNTERS[stage as usize].fetch_add(1, Ordering::Relaxed) % SAMPLE_EVERY == 0;
    Probe { start: sampled.then(Instant::now), stage: stage.name(), display }
}
impl Drop for Probe {
    fn drop(&mut self) {
        if let (Some(start), Some(Some(trace))) = (self.start, TRACE.get()) {
            let us = start.elapsed().as_micros().min(u64::MAX as u128) as u64;
            if trace.tx.try_send(Command::Sample(self.stage, self.display, us)).is_err() {
                DROPPED.fetch_add(1, Ordering::Relaxed);
            }
        }
    }
}

fn quoted(value: &str) -> String {
    let mut out = String::from("\"");
    for c in value.chars().take(2048) {
        match c {
            '"' => out.push_str("\\\""), '\\' => out.push_str("\\\\"),
            c if c <= '\u{1f}' => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

pub fn runtime_path(display: usize, config: &impl std::fmt::Debug, recording: bool, use_i444: bool) {
    if let Some(trace) = TRACE.get_or_init(initialize).as_ref() {
        let payload = quoted(&format!("{config:?}"));
        if trace.tx.try_send(Command::Runtime(display, payload, recording, use_i444)).is_err() {
            DROPPED.fetch_add(1, Ordering::Relaxed);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn percentile_is_an_upper_bound_and_storage_is_bounded() {
        let mut s = Stats::default();
        for n in 1..=100 { s.add(n); }
        assert_eq!(s.count, 100);
        assert_eq!(s.max, 100);
        assert_eq!(s.percentile_upper(95), 128);
        assert!(s.bins.len() <= 65);
    }
    #[test]
    fn log_limit_does_not_partially_write_an_event() {
        let mut out = Vec::new();
        let mut bytes = MAX_BYTES - 2;
        assert!(!write_bounded(&mut out, &mut bytes, "long event"));
        assert!(out.is_empty());
    }
    #[test]
    fn runtime_strings_are_json_escaped() {
        assert_eq!(quoted("a\n\"\\"), "\"a\\u000a\\\"\\\\\"");
    }
}
