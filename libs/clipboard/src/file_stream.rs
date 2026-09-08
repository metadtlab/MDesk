//! Native clipboard transport: TransferJob producer, bounded prefetch consumer.
//! OLE retains destination/seek semantics. IDs are scoped to the connection and
//! copy generation, and senders receive credit only as the consumer reads.
use serde_derive::{Deserialize, Serialize};

pub const REQUEST: u32 = 1;
pub const BLOCK: u32 = 2;
pub const END: u32 = 3;
pub const CREDIT: u32 = 4;
pub const CANCEL: u32 = 5;
pub const ERROR: u32 = 6;
pub const DESCRIPTORS_REQUEST: u32 = 7;
pub const DESCRIPTORS_RESPONSE: u32 = 8;
pub const FORMAT_PREFIX: &str = "MDesk.FileStream.v1:";
pub const BLOCK_BYTES: usize = 128 * 1024;
pub const WINDOW_BYTES: usize = 8 * BLOCK_BYTES;

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Frame {
    pub kind: u32,
    pub generation: u64,
    pub request_id: u64,
    pub index: u32,
    pub offset: u64,
    pub size: u64,
    pub data: Vec<u8>,
    pub compressed: bool,
}

pub fn generation(formats: &[(i32, String)]) -> u64 {
    formats
        .iter()
        .find_map(|(_, name)| {
            let value = name.strip_prefix(FORMAT_PREFIX)?;
            if value.len() != 16 {
                return None;
            }
            u64::from_str_radix(value, 16).ok().filter(|v| *v != 0)
        })
        .unwrap_or(0)
}

#[cfg(target_os = "windows")]
pub use windows::*;

#[cfg(target_os = "windows")]
mod windows {
    use super::*;
    use crate::{send_data, ClipboardFile};
    use hbb_common::{anyhow::anyhow, bail, fs::TransferJob, ResultType};
    use std::{
        collections::{HashMap, HashSet, VecDeque},
        path::PathBuf,
        sync::{Arc, Condvar, Mutex},
        time::{Duration, Instant},
    };

    const MAX_STREAMS: usize = 8;
    const TIMEOUT: Duration = Duration::from_secs(30);
    type Key = (i32, u64);
    type Shared<T> = Arc<(Mutex<T>, Condvar)>;
    #[derive(Default)]
    struct Source {
        sequence: u32,
        generation: u64,
        paths: Vec<Option<PathBuf>>,
    }
    #[derive(Default)]
    struct State {
        source: Source,
        snapshots: HashMap<u64, Snapshot>,
        remote: HashMap<i32, u64>,
        receiving: HashMap<Key, Shared<Receive>>,
        sending: HashMap<Key, Shared<SendWindow>>,
        metadata: HashMap<Key, Shared<Metadata>>,
    }
    struct Snapshot {
        paths: Vec<Option<PathBuf>>,
        descriptors: Vec<u8>,
        clients: HashSet<i32>,
        used: Instant,
    }
    struct Metadata {
        generation: u64,
        format: u32,
        result: Option<Result<Vec<u8>, ()>>,
    }
    lazy_static::lazy_static! { static ref STATE: Mutex<State> = Mutex::new(State::default()); }

    struct Receive {
        frame: Frame,
        consumed: u64,
        received: u64,
        chunks: VecDeque<Vec<u8>>,
        front: usize,
        ended: bool,
        failed: bool,
    }
    impl Receive {
        fn new(frame: Frame) -> Self {
            Self {
                consumed: frame.offset,
                received: frame.offset,
                frame,
                chunks: VecDeque::new(),
                front: 0,
                ended: false,
                failed: false,
            }
        }
        fn accept(&mut self, f: &Frame) -> ResultType<()> {
            if f.generation != self.frame.generation
                || f.index != self.frame.index
                || f.size != self.frame.size
                || f.offset != self.received
                || self.ended
                || self.failed
            {
                bail!("clipboard stream response mismatch");
            }
            match f.kind {
                BLOCK => {
                    if f.data.is_empty() || f.data.len() > BLOCK_BYTES {
                        bail!("invalid clipboard block");
                    }
                    let data = if f.compressed {
                        hbb_common::fs::decompress_direct_transfer_block(&f.data, BLOCK_BYTES)?
                    } else {
                        f.data.clone()
                    };
                    let remaining = self
                        .frame
                        .size
                        .checked_sub(self.received)
                        .ok_or_else(|| anyhow!("clipboard size overflow"))?;
                    if data.len() != remaining.min(BLOCK_BYTES as u64) as usize
                        || data.is_empty()
                        || self.received - self.consumed + data.len() as u64 > WINDOW_BYTES as u64
                    {
                        bail!("clipboard stream exceeds receive window or declared size");
                    }
                    self.received += data.len() as u64;
                    self.chunks.push_back(data);
                }
                END if f.data.is_empty() && !f.compressed && self.received == self.frame.size => {
                    self.ended = true
                }
                _ => bail!("invalid clipboard stream termination"),
            }
            Ok(())
        }
    }
    struct SendWindow {
        frame: Frame,
        sent: u64,
        acknowledged: u64,
        cancelled: bool,
    }

    fn emit(conn: i32, frame: Frame) -> ResultType<()> {
        send_data(conn, ClipboardFile::FileStream(frame)).map_err(|e| anyhow!(e))
    }
    pub fn reject(conn: i32, clip: &ClipboardFile) {
        if let ClipboardFile::FileStream(f) = clip {
            if matches!(f.kind, REQUEST | DESCRIPTORS_REQUEST) {
                let _ = emit(
                    conn,
                    Frame {
                        kind: ERROR,
                        data: vec![],
                        compressed: false,
                        ..f.clone()
                    },
                );
            }
        }
    }
    pub fn announce(sequence: u32, local_files: bool) -> u64 {
        let mut state = STATE.lock().unwrap();
        if !local_files {
            state.source = Source::default();
            return 0;
        }
        if state.source.sequence != sequence || state.source.generation == 0 {
            state.source = Source {
                sequence,
                generation: hbb_common::rand::random::<u64>().max(1),
                paths: vec![],
            };
        }
        state.source.generation
    }
    pub fn snapshot(sequence: u32, paths: Vec<Option<PathBuf>>) {
        let mut state = STATE.lock().unwrap();
        if state.source.sequence == sequence && paths.len() <= 16384 {
            state.source.paths = paths;
        }
    }
    pub fn remember_metadata(conn: i32, generation: u64, data: &[u8]) {
        let mut state = STATE.lock().unwrap();
        if state.source.generation != generation || data.len() > 4 + 16384 * 592 {
            return;
        }
        if state.snapshots.len() >= 32 && !state.snapshots.contains_key(&generation) {
            let oldest = state
                .snapshots
                .iter()
                .filter(|(gen, _)| {
                    !state
                        .sending
                        .values()
                        .any(|s| s.0.lock().unwrap().frame.generation == **gen)
                })
                .min_by_key(|(_, s)| s.used)
                .map(|(g, _)| *g);
            if let Some(oldest) = oldest {
                state.snapshots.remove(&oldest);
            }
        }
        let paths = state.source.paths.clone();
        let snapshot = state
            .snapshots
            .entry(generation)
            .or_insert_with(|| Snapshot {
                paths,
                descriptors: data.to_vec(),
                clients: HashSet::new(),
                used: Instant::now(),
            });
        snapshot.clients.insert(conn);
        snapshot.used = Instant::now();
    }
    pub fn cached_metadata(conn: i32, generation: u64) -> Option<Vec<u8>> {
        let mut state = STATE.lock().unwrap();
        let snapshot = state.snapshots.get_mut(&generation)?;
        if !snapshot.clients.contains(&conn) {
            return None;
        }
        snapshot.used = Instant::now();
        Some(snapshot.descriptors.clone())
    }
    pub fn set_remote_generation(conn: i32, generation: u64) {
        STATE.lock().unwrap().remote.insert(conn, generation);
    }
    pub fn remote_generation(conn: i32) -> u64 {
        STATE
            .lock()
            .unwrap()
            .remote
            .get(&conn)
            .copied()
            .unwrap_or(0)
    }
    pub fn source_is_current(generation: u64, sequence: u32) -> bool {
        let state = STATE.lock().unwrap();
        generation != 0
            && state.source.generation == generation
            && state.source.sequence == sequence
    }
    pub fn descriptors(conn: i32, generation: u64, format: u32) -> ResultType<Vec<u8>> {
        descriptors_with_timeout(conn, generation, format, TIMEOUT)
    }

    fn descriptors_with_timeout(
        conn: i32,
        generation: u64,
        format: u32,
        timeout: Duration,
    ) -> ResultType<Vec<u8>> {
        let id = hbb_common::rand::random::<u64>().max(1);
        let waiting = Arc::new((
            Mutex::new(Metadata {
                generation,
                format,
                result: None,
            }),
            Condvar::new(),
        ));
        {
            let mut state = STATE.lock().unwrap();
            if state.metadata.len() >= MAX_STREAMS || state.metadata.contains_key(&(conn, id)) {
                bail!("too many clipboard metadata requests");
            }
            state.metadata.insert((conn, id), waiting.clone());
        }
        let sent = emit(
            conn,
            Frame {
                kind: DESCRIPTORS_REQUEST,
                generation,
                request_id: id,
                index: format,
                ..Default::default()
            },
        );
        let result = if sent.is_ok() {
            let (mut guard, _) = waiting
                .1
                .wait_timeout_while(waiting.0.lock().unwrap(), timeout, |s| s.result.is_none())
                .unwrap();
            guard
                .result
                .take()
                .unwrap_or(Err(()))
                .map_err(|_| anyhow!("clipboard metadata failed or timed out"))
        } else {
            Err(anyhow!("clipboard metadata send failed"))
        };
        STATE.lock().unwrap().metadata.remove(&(conn, id));
        if result.is_err() {
            let _ = emit(
                conn,
                Frame {
                    kind: CANCEL,
                    generation,
                    request_id: id,
                    index: format,
                    ..Default::default()
                },
            );
        }
        result
    }

    fn start_send(conn: i32, f: Frame, _sequence: u32) -> ResultType<()> {
        if f.request_id == 0 || f.offset > f.size || !f.data.is_empty() || f.compressed {
            bail!("invalid stream request");
        }
        let (path, window) = {
            let mut state = STATE.lock().unwrap();
            if state.sending.len() >= MAX_STREAMS
                || state.sending.contains_key(&(conn, f.request_id))
                || f.generation == 0
            {
                bail!("clipboard source changed or busy");
            }
            let snapshot = state
                .snapshots
                .get_mut(&f.generation)
                .filter(|s| s.clients.contains(&conn))
                .ok_or_else(|| {
                    anyhow!("clipboard generation is not authorized for this connection")
                })?;
            snapshot.used = Instant::now();
            let path = snapshot
                .paths
                .get(f.index as usize)
                .and_then(|p| p.as_ref())
                .cloned()
                .ok_or_else(|| anyhow!("clipboard file is unavailable"))?;
            let window = Arc::new((
                Mutex::new(SendWindow {
                    sent: f.offset,
                    acknowledged: f.offset,
                    cancelled: false,
                    frame: f.clone(),
                }),
                Condvar::new(),
            ));
            state.sending.insert((conn, f.request_id), window.clone());
            (path, window)
        };
        let key = (conn, f.request_id);
        let failure = f.clone();
        let result = std::thread::Builder::new()
            .name("clipboard-file-send".into())
            .spawn(move || {
                let run = || -> ResultType<()> {
                    // A network-backed local path may block on open. Keep that off
                    // the clipboard dispatcher and outside the global state lock.
                    if window.0.lock().unwrap().cancelled {
                        bail!("clipboard stream cancelled");
                    }
                    let file = hbb_common::fs::open_file_for_read(&path)?;
                    let audit_path = path.to_string_lossy().to_string();
                    let metadata = file.metadata()?;
                    if !metadata.is_file() || metadata.len() != f.size {
                        bail!("clipboard source size changed");
                    }
                    let rt = hbb_common::tokio::runtime::Builder::new_current_thread()
                        .enable_all()
                        .build()?;
                    rt.block_on(async {
                        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
                        let mut job =
                            TransferJob::from_clipboard_file(file, f.offset, name).await?;
                        let mut offset = f.offset;
                        let mut audit_sent = false;
                        while offset < f.size {
                            let needed = (f.size - offset).min(BLOCK_BYTES as u64);
                            let (lock, wake) = &*window;
                            let guard = lock.lock().unwrap();
                            let (guard, timed) = wake
                                .wait_timeout_while(guard, TIMEOUT, |s| {
                                    !s.cancelled
                                        && s.sent - s.acknowledged + needed > WINDOW_BYTES as u64
                                })
                                .unwrap();
                            if guard.cancelled || timed.timed_out() {
                                bail!("clipboard stream cancelled or credit timeout");
                            }
                            drop(guard);
                            let before = job.finished_size();
                            let block = job
                                .read()
                                .await?
                                .ok_or_else(|| anyhow!("clipboard source ended early"))?;
                            if block.data.is_empty() {
                                bail!("clipboard source ended early");
                            }
                            // The shared TransferJob reader emits exactly 128 KiB except at EOF.
                            if job.finished_size().saturating_sub(before) != needed {
                                bail!("clipboard source changed during transfer");
                            }
                            {
                                let mut s = lock.lock().unwrap();
                                if s.cancelled {
                                    bail!("clipboard stream cancelled");
                                }
                                s.sent += needed;
                            }
                            if !audit_sent {
                                let _ = send_data(
                                    conn,
                                    ClipboardFile::Files {
                                        files: vec![(audit_path.clone(), f.size)],
                                        source_application: 0,
                                    },
                                );
                                audit_sent = true;
                            }
                            emit(
                                conn,
                                Frame {
                                    kind: BLOCK,
                                    offset,
                                    data: block.data.into(),
                                    compressed: block.compressed,
                                    ..f.clone()
                                },
                            )?;
                            offset += needed;
                        }
                        emit(
                            conn,
                            Frame {
                                kind: END,
                                offset,
                                ..f.clone()
                            },
                        )
                    })
                };
                if let Err(e) = run() {
                    hbb_common::log::debug!("Clipboard stream ended: {}", e);
                    let _ = emit(
                        conn,
                        Frame {
                            kind: ERROR,
                            ..f.clone()
                        },
                    );
                }
                STATE.lock().unwrap().sending.remove(&key);
            });
        if result.is_err() {
            STATE.lock().unwrap().sending.remove(&key);
            let _ = emit(
                conn,
                Frame {
                    kind: ERROR,
                    ..failure
                },
            );
            bail!("cannot start clipboard sender");
        }
        Ok(())
    }

    pub fn handle(conn: i32, f: Frame, local_sequence: u32) {
        let key = (conn, f.request_id);
        if f.kind == DESCRIPTORS_RESPONSE || f.kind == ERROR {
            let metadata = STATE.lock().unwrap().metadata.get(&key).cloned();
            if let Some(metadata) = metadata {
                let mut s = metadata.0.lock().unwrap();
                if s.generation == f.generation
                    && s.format == f.index
                    && f.offset == 0
                    && f.size == 0
                    && s.result.is_none()
                {
                    s.result = Some(
                        if f.kind == DESCRIPTORS_RESPONSE
                            && !f.compressed
                            && f.data.len() >= 4
                            && f.data.len() <= 4 + 16384 * 592
                        {
                            Ok(f.data)
                        } else {
                            Err(())
                        },
                    );
                    metadata.1.notify_all();
                }
                return;
            }
        }
        match f.kind {
            REQUEST => {
                if let Err(e) = start_send(conn, f.clone(), local_sequence) {
                    hbb_common::log::debug!("Clipboard stream rejected: {}", e);
                    let _ = emit(
                        conn,
                        Frame {
                            kind: ERROR,
                            data: vec![],
                            compressed: false,
                            ..f
                        },
                    );
                }
            }
            BLOCK | END | ERROR => {
                let receiver = STATE.lock().unwrap().receiving.get(&key).cloned();
                if let Some(receiver) = receiver {
                    let (lock, wake) = &*receiver;
                    let mut s = lock.lock().unwrap();
                    if f.generation != s.frame.generation
                        || f.index != s.frame.index
                        || f.size != s.frame.size
                    {
                        return;
                    }
                    if s.accept(&f).is_err() {
                        s.failed = true;
                    }
                    wake.notify_all();
                }
            }
            CREDIT | CANCEL => {
                let sender = STATE.lock().unwrap().sending.get(&key).cloned();
                if let Some(sender) = sender {
                    let (lock, wake) = &*sender;
                    let mut s = lock.lock().unwrap();
                    if f.generation != s.frame.generation
                        || f.index != s.frame.index
                        || f.size != s.frame.size
                    {
                        return;
                    }
                    if f.kind == CANCEL
                        || !f.data.is_empty()
                        || f.compressed
                        || f.offset < s.acknowledged
                        || f.offset > s.sent
                    {
                        s.cancelled = true;
                    } else {
                        s.acknowledged = f.offset;
                    }
                    wake.notify_all();
                }
            }
            _ => {}
        }
    }

    pub fn release(conn: i32, id: u64) {
        let receiver = STATE.lock().unwrap().receiving.remove(&(conn, id));
        if let Some(receiver) = receiver {
            let (lock, wake) = &*receiver;
            let mut s = lock.lock().unwrap();
            s.failed = true;
            wake.notify_all();
            let frame = Frame {
                kind: CANCEL,
                offset: s.consumed,
                ..s.frame.clone()
            };
            drop(s);
            let _ = emit(conn, frame);
        }
    }
    pub fn disconnect(conn: i32) {
        let (receivers, senders) = {
            let mut state = STATE.lock().unwrap();
            state.remote.remove(&conn);
            state.snapshots.retain(|_, s| {
                s.clients.remove(&conn);
                !s.clients.is_empty()
            });
            for (_, waiting) in state.metadata.iter().filter(|(key, _)| key.0 == conn) {
                waiting.0.lock().unwrap().result = Some(Err(()));
                waiting.1.notify_all();
            }
            (
                state
                    .receiving
                    .keys()
                    .filter(|k| k.0 == conn)
                    .map(|k| k.1)
                    .collect::<Vec<_>>(),
                state
                    .sending
                    .iter()
                    .filter(|(k, _)| k.0 == conn)
                    .map(|(_, v)| v.clone())
                    .collect::<Vec<_>>(),
            )
        };
        for id in receivers {
            release(conn, id);
        }
        for sender in senders {
            sender.0.lock().unwrap().cancelled = true;
            sender.1.notify_all();
        }
    }

    pub fn read(
        conn: i32,
        generation: u64,
        index: u32,
        size: u64,
        offset: u64,
        output: &mut [u8],
        token: &mut u64,
    ) -> ResultType<usize> {
        if generation == 0 || offset > size {
            bail!("invalid clipboard read");
        }
        if output.is_empty() || offset == size {
            return Ok(0);
        }
        let mut receiver = STATE
            .lock()
            .unwrap()
            .receiving
            .get(&(conn, *token))
            .cloned();
        if let Some(r) = &receiver {
            let s = r.0.lock().unwrap();
            if s.consumed != offset
                || s.frame.generation != generation
                || s.frame.index != index
                || s.frame.size != size
            {
                drop(s);
                release(conn, *token);
                receiver = None;
            }
        }
        if receiver.is_none() {
            let mut state = STATE.lock().unwrap();
            if state.receiving.len() >= MAX_STREAMS {
                bail!("too many clipboard streams");
            }
            let id = loop {
                let id = hbb_common::rand::random::<u64>().max(1);
                if !state.receiving.contains_key(&(conn, id)) {
                    break id;
                }
            };
            let frame = Frame {
                kind: REQUEST,
                generation,
                request_id: id,
                index,
                offset,
                size,
                ..Default::default()
            };
            let r = Arc::new((Mutex::new(Receive::new(frame.clone())), Condvar::new()));
            state.receiving.insert((conn, id), r.clone());
            *token = id;
            drop(state);
            if let Err(e) = emit(conn, frame) {
                release(conn, id);
                return Err(e);
            }
            receiver = Some(r);
        }
        let receiver = receiver.unwrap();
        let mut done = 0;
        let wanted = output
            .len()
            .min((size - offset).min(usize::MAX as u64) as usize);
        let deadline = Instant::now() + TIMEOUT;
        while done < wanted {
            let (lock, wake) = &*receiver;
            let s = lock.lock().unwrap();
            let (mut s, timed) = wake
                .wait_timeout_while(s, deadline.saturating_duration_since(Instant::now()), |s| {
                    s.chunks.is_empty() && !s.failed && !s.ended
                })
                .unwrap();
            if s.failed || timed.timed_out() || s.chunks.is_empty() {
                bail!("clipboard stream interrupted or timed out");
            }
            let front = s.chunks.front().unwrap();
            let count = (front.len() - s.front).min(wanted - done);
            output[done..done + count].copy_from_slice(&front[s.front..s.front + count]);
            s.front += count;
            s.consumed += count as u64;
            done += count;
            let exhausted = s.front == s.chunks.front().unwrap().len();
            let credit = if exhausted {
                s.chunks.pop_front();
                s.front = 0;
                Some(Frame {
                    kind: CREDIT,
                    offset: s.consumed,
                    ..s.frame.clone()
                })
            } else {
                None
            };
            drop(s);
            if let Some(credit) = credit {
                emit(conn, credit)?;
            }
        }
        if offset + done as u64 == size {
            let (s, timed) = receiver
                .1
                .wait_timeout_while(receiver.0.lock().unwrap(), TIMEOUT, |s| {
                    !s.ended && !s.failed
                })
                .unwrap();
            if s.failed || timed.timed_out() {
                bail!("clipboard stream did not complete");
            }
            drop(s);
            release(conn, *token);
            *token = 0;
        }
        Ok(done)
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        static SOURCE_TEST: Mutex<()> = Mutex::new(());
        fn frame(size: u64) -> Frame {
            Frame {
                kind: REQUEST,
                generation: 7,
                request_id: 9,
                index: 2,
                size,
                ..Default::default()
            }
        }
        #[test]
        fn receive_rejects_wrong_generation_offset_size_and_oversized_block() {
            for f in [
                Frame {
                    kind: BLOCK,
                    generation: 8,
                    data: vec![1],
                    ..frame(1)
                },
                Frame {
                    kind: BLOCK,
                    offset: 1,
                    data: vec![1],
                    ..frame(1)
                },
                Frame {
                    kind: BLOCK,
                    size: 2,
                    data: vec![1],
                    ..frame(1)
                },
                Frame {
                    kind: BLOCK,
                    data: vec![1; BLOCK_BYTES + 1],
                    ..frame(1)
                },
            ] {
                assert!(Receive::new(frame(1)).accept(&f).is_err());
            }
        }
        #[test]
        fn receive_bounds_prefetch_and_validates_end() {
            let f = frame((WINDOW_BYTES + BLOCK_BYTES) as u64);
            let mut r = Receive::new(f.clone());
            for n in 0..8 {
                r.accept(&Frame {
                    kind: BLOCK,
                    offset: (n * BLOCK_BYTES) as u64,
                    data: vec![0; BLOCK_BYTES],
                    ..f.clone()
                })
                .unwrap();
            }
            assert!(r
                .accept(&Frame {
                    kind: BLOCK,
                    offset: WINDOW_BYTES as u64,
                    data: vec![0; BLOCK_BYTES],
                    ..f.clone()
                })
                .is_err());
            assert!(r
                .accept(&Frame {
                    kind: END,
                    offset: WINDOW_BYTES as u64,
                    ..f
                })
                .is_err());
        }
        #[test]
        fn compressed_block_is_bounded_and_eof_exact() {
            let mut r = Receive::new(frame(3));
            r.accept(&Frame {
                kind: BLOCK,
                data: hbb_common::compress::compress(b"abc"),
                compressed: true,
                ..frame(3)
            })
            .unwrap();
            r.accept(&Frame {
                kind: END,
                offset: 3,
                ..frame(3)
            })
            .unwrap();
            assert!(r
                .accept(&Frame {
                    kind: END,
                    offset: 3,
                    ..frame(3)
                })
                .is_err());
            let bomb = hbb_common::compress::compress(&vec![0; BLOCK_BYTES + 1]);
            assert!(Receive::new(frame(BLOCK_BYTES as u64))
                .accept(&Frame {
                    kind: BLOCK,
                    data: bomb,
                    compressed: true,
                    ..frame(BLOCK_BYTES as u64)
                })
                .is_err());
        }
        #[test]
        fn source_generation_is_stable_only_for_same_copy() {
            let _guard = SOURCE_TEST.lock().unwrap();
            let a = announce(101, true);
            assert_eq!(a, announce(101, true));
            assert_ne!(a, announce(102, true));
            assert_eq!(0, announce(102, false));
        }
        #[test]
        fn marker_requires_exact_version_and_nonzero_generation() {
            assert_eq!(
                generation(&[(0, format!("{FORMAT_PREFIX}00000000000000ff"))]),
                255
            );
            assert_eq!(generation(&[(0, format!("{FORMAT_PREFIX}0"))]), 0);
        }
        #[test]
        fn metadata_correlates_generation_and_disconnect_wakes_only_its_waiter() {
            let a = crate::get_rx_cliprdr_server(8101);
            let b = crate::get_rx_cliprdr_server(8102);
            let first = std::thread::spawn(|| descriptors(8101, 77, 123));
            let second = std::thread::spawn(|| descriptors(8102, 88, 123));
            let rt = hbb_common::tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            let (fa, fb) = rt.block_on(async {
                let ClipboardFile::FileStream(fa) = a.lock().await.recv().await.unwrap() else {
                    panic!()
                };
                let ClipboardFile::FileStream(fb) = b.lock().await.recv().await.unwrap() else {
                    panic!()
                };
                (fa, fb)
            });
            handle(
                8102,
                Frame {
                    kind: DESCRIPTORS_RESPONSE,
                    generation: 77,
                    data: vec![0; 4],
                    ..fb.clone()
                },
                0,
            );
            assert!(STATE.lock().unwrap().metadata[&(8102, fb.request_id)]
                .0
                .lock()
                .unwrap()
                .result
                .is_none());
            disconnect(8101);
            assert!(first.join().unwrap().is_err());
            assert!(STATE
                .lock()
                .unwrap()
                .metadata
                .contains_key(&(8102, fb.request_id)));
            handle(
                8102,
                Frame {
                    kind: DESCRIPTORS_RESPONSE,
                    data: vec![0; 4],
                    ..fb
                },
                0,
            );
            assert_eq!(second.join().unwrap().unwrap(), vec![0; 4]);
            let cancelled = rt.block_on(async { a.lock().await.recv().await.unwrap() });
            assert!(
                matches!(cancelled, ClipboardFile::FileStream(f) if f.kind == CANCEL && f.request_id == fa.request_id)
            );
            disconnect(8102);
            crate::remove_channel_by_conn_id(8101);
            crate::remove_channel_by_conn_id(8102);
        }
        #[test]
        fn empty_files_need_no_transfer_and_unauthorized_paths_are_rejected() {
            let mut token = 0;
            assert_eq!(read(8103, 77, 0, 0, 0, &mut [0; 8], &mut token).unwrap(), 0);
            assert_eq!(token, 0);
            assert!(read(8103, 77, 0, 0, 1, &mut [0; 8], &mut token).is_err());
            assert!(start_send(
                8103,
                Frame {
                    generation: u64::MAX,
                    ..frame(100)
                },
                0
            )
            .is_err());
        }
        #[test]
        fn metadata_timeout_removes_waiter_and_sends_cancel() {
            let rx = crate::get_rx_cliprdr_server(8104);
            assert!(descriptors_with_timeout(8104, 99, 123, Duration::from_millis(10)).is_err());
            assert!(!STATE.lock().unwrap().metadata.keys().any(|k| k.0 == 8104));
            let rt = hbb_common::tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            rt.block_on(async {
                let mut rx = rx.lock().await;
                let ClipboardFile::FileStream(request) = rx.recv().await.unwrap() else {
                    panic!()
                };
                let ClipboardFile::FileStream(cancel) = rx.recv().await.unwrap() else {
                    panic!()
                };
                assert_eq!(request.kind, DESCRIPTORS_REQUEST);
                assert_eq!(cancel.kind, CANCEL);
                assert_eq!(request.request_id, cancel.request_id);
            });
            crate::remove_channel_by_conn_id(8104);
        }
        #[test]
        fn transfer_job_streams_multiple_windows_and_seek_without_content_changes() {
            let _guard = SOURCE_TEST.lock().unwrap();
            let root = std::env::temp_dir().join(format!(
                "mdesk-stream-test-{}",
                hbb_common::uuid::Uuid::new_v4()
            ));
            std::fs::create_dir(&root).unwrap();
            let path = root.join("payload.zip");
            let expected = (0..(WINDOW_BYTES * 3 + 51))
                .map(|n| (n % 251) as u8)
                .collect::<Vec<_>>();
            std::fs::write(&path, &expected).unwrap();
            let generation = announce(999, true);
            snapshot(999, vec![Some(path.clone())]);
            remember_metadata(8001, generation, &[1, 0, 0, 0]);
            let tx_source = crate::get_rx_cliprdr_server(8001);
            let tx_sink = crate::get_rx_cliprdr_server(8002);
            let bytes = expected.clone();
            let reader = std::thread::spawn(move || {
                let mut token = 0;
                let mut actual = vec![0; bytes.len()];
                let mut offset = 0;
                while offset < bytes.len() {
                    let end = (offset + 200_000).min(bytes.len());
                    let n = read(
                        8002,
                        generation,
                        0,
                        bytes.len() as u64,
                        offset as u64,
                        &mut actual[offset..end],
                        &mut token,
                    )
                    .unwrap();
                    offset += n;
                }
                assert_eq!(actual, bytes);
                // A new Ctrl+C must not redirect an already acquired file list.
                announce(1000, true);
                let mut seek = vec![0; 8192];
                assert_eq!(
                    read(
                        8002,
                        generation,
                        0,
                        bytes.len() as u64,
                        777,
                        &mut seek,
                        &mut token
                    )
                    .unwrap(),
                    8192
                );
                assert_eq!(seek, bytes[777..777 + 8192]);
                release(8002, token);
                token = 0;
                // Completed streams must release quota even if Explorer keeps
                // all of its IStream objects alive for the whole file group.
                for _ in 0..12 {
                    let mut tail = [0; 17];
                    read(
                        8002,
                        generation,
                        0,
                        bytes.len() as u64,
                        (bytes.len() - 17) as u64,
                        &mut tail,
                        &mut token,
                    )
                    .unwrap();
                    assert_eq!(tail, bytes[bytes.len() - 17..]);
                    assert_eq!(token, 0);
                }
                assert_eq!(
                    read(
                        8002,
                        generation,
                        0,
                        bytes.len() as u64,
                        bytes.len() as u64,
                        &mut seek,
                        &mut token
                    )
                    .unwrap(),
                    0
                );
                release(8002, token);
            });
            let rt = hbb_common::tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            rt.block_on(async {
                let mut source = tx_source.lock().await;
                let mut sink = tx_sink.lock().await;
                while !reader.is_finished() {
                    hbb_common::tokio::select! {
                        Some(ClipboardFile::FileStream(f)) = source.recv() => {
                            // Preserve TransferJob's skip-compression policy for archives.
                            if f.kind == BLOCK { assert!(!f.compressed); }
                            handle(8002, f, 999)
                        },
                        Some(ClipboardFile::FileStream(f)) = sink.recv() => handle(8001, f, 999),
                        _ = hbb_common::tokio::time::sleep(Duration::from_millis(10)) => {},
                    }
                }
            });
            reader.join().unwrap();
            disconnect(8001);
            disconnect(8002);
            crate::remove_channel_by_conn_id(8001);
            crate::remove_channel_by_conn_id(8002);
            // Sender cancellation releases its open file asynchronously.
            for _ in 0..100 {
                if !STATE.lock().unwrap().sending.keys().any(|k| k.0 == 8001) {
                    break;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            std::fs::remove_file(path).unwrap();
            std::fs::remove_dir(root).unwrap();
        }
    }
}
