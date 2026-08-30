use super::*;
#[cfg(not(target_os = "android"))]
use crate::clipboard::clipboard_listener;
#[cfg(not(target_os = "android"))]
pub use crate::clipboard::{check_clipboard, ClipboardContext, ClipboardSide};
pub use crate::clipboard::{CLIPBOARD_INTERVAL as INTERVAL, CLIPBOARD_NAME as NAME};
#[cfg(windows)]
use crate::ipc::{self, ClipboardFile, ClipboardNonFile, Data};
#[cfg(feature = "unix-file-copy-paste")]
pub use crate::{
    clipboard::{check_clipboard_files, FILE_CLIPBOARD_NAME as FILE_NAME},
    clipboard_file::unix_file_clip,
};
#[cfg(all(feature = "unix-file-copy-paste", target_os = "linux"))]
use clipboard::platform::unix::fuse::{init_fuse_context, uninit_fuse_context};
#[cfg(not(target_os = "android"))]
use clipboard_master::CallbackResult;
#[cfg(target_os = "android")]
use hbb_common::config::{keys, option2bool};
#[cfg(target_os = "android")]
use std::sync::atomic::{AtomicBool, Ordering};
use std::{
    io,
    sync::mpsc::{channel, RecvTimeoutError},
    time::Duration,
};
#[cfg(not(target_os = "android"))]
use std::{sync::mpsc::Receiver, time::Instant};
#[cfg(windows)]
use tokio::runtime::Runtime;

#[cfg(target_os = "android")]
static CLIPBOARD_SERVICE_OK: AtomicBool = AtomicBool::new(false);

#[cfg(not(target_os = "android"))]
struct Handler {
    ctx: Option<ClipboardContext>,
    #[cfg(target_os = "windows")]
    stream: Option<ipc::ConnectionTmpl<parity_tokio_ipc::ConnectionClient>>,
    #[cfg(target_os = "windows")]
    rt: Option<Runtime>,
}

#[cfg(not(target_os = "android"))]
const CLIPBOARD_LISTENER_QUIET_WINDOW: Duration = Duration::from_millis(INTERVAL);
#[cfg(not(target_os = "android"))]
const CLIPBOARD_LISTENER_BURST_HARD_CAP: Duration = Duration::from_secs(2);

#[cfg(not(target_os = "android"))]
enum ClipboardListenerBurstCompletion {
    Ready,
    Stop,
    StopWithError(io::Error),
    Disconnected,
}

/// Coalesces a listener notification burst before clipboard contents are read.
/// Some applications (notably Excel) emit several `Next` callbacks for one
/// logical copy. Waiting for a trailing quiet window makes that burst produce a
/// single snapshot without retaining or fingerprinting clipboard contents.
/// The hard cap prevents a noisy producer from postponing delivery forever.
#[cfg(not(target_os = "android"))]
fn coalesce_clipboard_listener_burst(
    receiver: &Receiver<CallbackResult>,
    quiet_window: Duration,
    hard_cap: Duration,
) -> ClipboardListenerBurstCompletion {
    let started_at = Instant::now();
    let hard_deadline = started_at + hard_cap;
    let mut quiet_deadline = (started_at + quiet_window).min(hard_deadline);

    loop {
        let now = Instant::now();
        let deadline = quiet_deadline.min(hard_deadline);
        let Some(wait) = deadline.checked_duration_since(now) else {
            return ClipboardListenerBurstCompletion::Ready;
        };

        match receiver.recv_timeout(wait) {
            Ok(CallbackResult::Next) => {
                quiet_deadline = (Instant::now() + quiet_window).min(hard_deadline);
            }
            Ok(CallbackResult::Stop) => return ClipboardListenerBurstCompletion::Stop,
            Ok(CallbackResult::StopWithError(err)) => {
                return ClipboardListenerBurstCompletion::StopWithError(err)
            }
            Err(RecvTimeoutError::Timeout) => return ClipboardListenerBurstCompletion::Ready,
            Err(RecvTimeoutError::Disconnected) => {
                return ClipboardListenerBurstCompletion::Disconnected
            }
        }
    }
}

#[cfg(target_os = "android")]
pub fn is_clipboard_service_ok() -> bool {
    CLIPBOARD_SERVICE_OK.load(Ordering::SeqCst)
}

pub fn new(name: String) -> GenericService {
    let svc = EmptyExtraFieldService::new(name, false);
    GenericService::run(&svc.clone(), run);
    svc.sp
}

#[cfg(not(target_os = "android"))]
fn run(sp: EmptyExtraFieldService) -> ResultType<()> {
    #[cfg(all(feature = "unix-file-copy-paste", target_os = "linux"))]
    let _fuse_call_on_ret = {
        if sp.name() == FILE_NAME {
            Some(init_fuse_context(false).map(|_| crate::SimpleCallOnReturn {
                b: true,
                f: Box::new(|| {
                    uninit_fuse_context(false);
                }),
            }))
        } else {
            None
        }
    };

    let (tx_cb_result, rx_cb_result) = channel();
    let ctx = Some(ClipboardContext::new().map_err(|e| io::Error::new(io::ErrorKind::Other, e))?);
    clipboard_listener::subscribe(sp.name(), tx_cb_result)?;
    let mut handler = Handler {
        ctx,
        #[cfg(target_os = "windows")]
        stream: None,
        #[cfg(target_os = "windows")]
        rt: None,
    };
    let mut stop_error = None;

    while sp.ok() {
        match rx_cb_result.recv_timeout(Duration::from_millis(INTERVAL)) {
            Ok(CallbackResult::Next) => {
                let completion = coalesce_clipboard_listener_burst(
                    &rx_cb_result,
                    CLIPBOARD_LISTENER_QUIET_WINDOW,
                    CLIPBOARD_LISTENER_BURST_HARD_CAP,
                );

                match completion {
                    ClipboardListenerBurstCompletion::Ready => {
                        #[cfg(feature = "unix-file-copy-paste")]
                        if sp.name() == FILE_NAME {
                            handler.check_clipboard_file();
                        } else if let Some(msg) = handler.get_clipboard_msg() {
                            sp.send(msg);
                        }
                        #[cfg(not(feature = "unix-file-copy-paste"))]
                        if let Some(msg) = handler.get_clipboard_msg() {
                            sp.send(msg);
                        }
                    }
                    ClipboardListenerBurstCompletion::Stop => {
                        log::debug!("Clipboard listener stopped");
                        break;
                    }
                    ClipboardListenerBurstCompletion::StopWithError(err) => {
                        stop_error = Some(err);
                        break;
                    }
                    ClipboardListenerBurstCompletion::Disconnected => {
                        log::error!("Clipboard listener disconnected");
                        break;
                    }
                }
            }
            Ok(CallbackResult::Stop) => {
                log::debug!("Clipboard listener stopped");
                break;
            }
            Ok(CallbackResult::StopWithError(err)) => {
                stop_error = Some(err);
                break;
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => {
                log::error!("Clipboard listener disconnected");
                break;
            }
        }
    }

    clipboard_listener::unsubscribe(&sp.name());

    if let Some(err) = stop_error {
        bail!("Clipboard listener stopped with error: {}", err);
    }

    Ok(())
}

#[cfg(all(test, not(target_os = "android")))]
mod clipboard_listener_burst_tests {
    use super::*;
    use std::sync::mpsc::TryRecvError;

    #[test]
    fn coalesces_all_queued_next_callbacks_into_one_ready_snapshot() {
        let (sender, receiver) = channel();
        for _ in 0..10 {
            sender.send(CallbackResult::Next).unwrap();
        }

        assert!(matches!(receiver.recv(), Ok(CallbackResult::Next)));
        assert!(matches!(
            coalesce_clipboard_listener_burst(
                &receiver,
                Duration::from_millis(10),
                Duration::from_millis(100),
            ),
            ClipboardListenerBurstCompletion::Ready
        ));
        assert!(matches!(receiver.try_recv(), Err(TryRecvError::Empty)));
    }

    #[test]
    fn callbacks_after_a_quiet_gap_start_a_new_snapshot() {
        let (sender, receiver) = channel();

        sender.send(CallbackResult::Next).unwrap();
        assert!(matches!(receiver.recv(), Ok(CallbackResult::Next)));
        assert!(matches!(
            coalesce_clipboard_listener_burst(
                &receiver,
                Duration::from_millis(5),
                Duration::from_millis(50),
            ),
            ClipboardListenerBurstCompletion::Ready
        ));

        sender.send(CallbackResult::Next).unwrap();
        assert!(matches!(receiver.recv(), Ok(CallbackResult::Next)));
        assert!(matches!(
            coalesce_clipboard_listener_burst(
                &receiver,
                Duration::from_millis(5),
                Duration::from_millis(50),
            ),
            ClipboardListenerBurstCompletion::Ready
        ));
    }

    #[test]
    fn preserves_stop_received_inside_a_burst() {
        let (sender, receiver) = channel();
        sender.send(CallbackResult::Stop).unwrap();

        assert!(matches!(
            coalesce_clipboard_listener_burst(
                &receiver,
                Duration::from_millis(10),
                Duration::from_millis(100),
            ),
            ClipboardListenerBurstCompletion::Stop
        ));
    }

    #[test]
    fn preserves_error_received_inside_a_burst() {
        let (sender, receiver) = channel();
        sender
            .send(CallbackResult::StopWithError(io::Error::new(
                io::ErrorKind::Other,
                "listener failed",
            )))
            .unwrap();

        match coalesce_clipboard_listener_burst(
            &receiver,
            Duration::from_millis(10),
            Duration::from_millis(100),
        ) {
            ClipboardListenerBurstCompletion::StopWithError(err) => {
                assert_eq!(err.to_string(), "listener failed")
            }
            _ => panic!("listener error was not preserved"),
        }
    }

    #[test]
    fn preserves_disconnect_received_inside_a_burst() {
        let (sender, receiver) = channel();
        drop(sender);

        assert!(matches!(
            coalesce_clipboard_listener_burst(
                &receiver,
                Duration::from_millis(10),
                Duration::from_millis(100),
            ),
            ClipboardListenerBurstCompletion::Disconnected
        ));
    }

    #[test]
    fn hard_cap_prevents_a_continuous_burst_from_starving_delivery() {
        let (sender, receiver) = channel();
        let producer = std::thread::spawn(move || {
            for _ in 0..30 {
                if sender.send(CallbackResult::Next).is_err() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(2));
            }
        });
        let started_at = Instant::now();

        assert!(matches!(
            coalesce_clipboard_listener_burst(
                &receiver,
                Duration::from_millis(10),
                Duration::from_millis(30),
            ),
            ClipboardListenerBurstCompletion::Ready
        ));
        assert!(started_at.elapsed() < Duration::from_millis(100));
        producer.join().unwrap();
    }
}

#[cfg(not(target_os = "android"))]
impl Handler {
    #[cfg(feature = "unix-file-copy-paste")]
    fn check_clipboard_file(&mut self) {
        if let Some(urls) = check_clipboard_files(&mut self.ctx, ClipboardSide::Host, false) {
            if !urls.is_empty() {
                #[cfg(target_os = "macos")]
                if crate::clipboard::is_file_url_set_by_rustdesk(&urls) {
                    return;
                }
                match clipboard::platform::unix::serv_files::sync_files(&urls) {
                    Ok(()) => {
                        // Use `send_data()` here to reuse `handle_file_clip()` in `connection.rs`.
                        hbb_common::allow_err!(clipboard::send_data(
                            0,
                            unix_file_clip::get_format_list()
                        ));
                    }
                    Err(e) => {
                        log::error!("Failed to sync clipboard files: {}", e);
                    }
                }
            }
        }
    }

    fn get_clipboard_msg(&mut self) -> Option<Message> {
        #[cfg(target_os = "windows")]
        if crate::common::is_server() && crate::platform::is_root() {
            match self.read_clipboard_from_cm_ipc() {
                Err(e) => {
                    log::error!("Failed to read clipboard from cm: {}", e);
                }
                Ok(data) => {
                    // Skip sending empty clipboard data.
                    // Maybe there's something wrong reading the clipboard data in cm, but no error msg is returned.
                    // The clipboard data should not be empty, the last line will try again to get the clipboard data.
                    if !data.is_empty() {
                        let mut msg = Message::new();
                        let multi_clipboards = MultiClipboards {
                            clipboards: data
                                .into_iter()
                                .map(|c| Clipboard {
                                    compress: c.compress,
                                    content: c.content,
                                    width: c.width,
                                    height: c.height,
                                    format: ClipboardFormat::from_i32(c.format)
                                        .unwrap_or(ClipboardFormat::Text)
                                        .into(),
                                    special_name: c.special_name,
                                    source_application: c.source_application.to_proto().into(),
                                    ..Default::default()
                                })
                                .collect(),
                            ..Default::default()
                        };
                        msg.set_multi_clipboards(multi_clipboards);
                        return Some(msg);
                    }
                }
            }
        }

        check_clipboard(&mut self.ctx, ClipboardSide::Host, false)
    }

    // Read clipboard data from cm using ipc.
    //
    // We cannot use `#[tokio::main(flavor = "current_thread")]` here,
    // because the auto-managed tokio runtime (async context) will be dropped after the call.
    // The next call will create a new runtime, which will cause the previous stream to be unusable.
    // So we need to manage the tokio runtime manually.
    #[cfg(windows)]
    fn read_clipboard_from_cm_ipc(&mut self) -> ResultType<Vec<ClipboardNonFile>> {
        if self.rt.is_none() {
            self.rt = Some(Runtime::new()?);
        }
        let Some(rt) = &self.rt else {
            // unreachable!
            bail!("failed to get tokio runtime");
        };
        let mut is_sent = false;
        if let Some(stream) = &mut self.stream {
            // If previous stream is still alive, reuse it.
            // If the previous stream is dead, `is_sent` will trigger reconnect.
            is_sent = match rt.block_on(stream.send(&Data::ClipboardNonFile(None))) {
                Ok(_) => true,
                Err(e) => {
                    log::debug!("Failed to send to cm: {}", e);
                    false
                }
            };
        }
        if !is_sent {
            let mut stream = rt.block_on(crate::ipc::connect(100, "_cm"))?;
            rt.block_on(stream.send(&Data::ClipboardNonFile(None)))?;
            self.stream = Some(stream);
        }

        if let Some(stream) = &mut self.stream {
            loop {
                match rt.block_on(stream.next_timeout(800))? {
                    Some(Data::ClipboardNonFile(Some((err, mut contents)))) => {
                        if !err.is_empty() {
                            bail!("{}", err);
                        } else {
                            if contents.iter().any(|c| c.next_raw) {
                                // Wrap the future with a `Timeout` in an async block to avoid panic.
                                // We cannot use `rt.block_on(timeout(1000, stream.next_raw()))` here, because it causes panic:
                                // thread '<unnamed>' panicked at D:\Projects\rust\rustdesk\libs\hbb_common\src\lib.rs:98:5:
                                // there is no reactor running, must be called from the context of a Tokio 1.x runtime
                                // note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
                                match rt.block_on(async { timeout(1000, stream.next_raw()).await })
                                {
                                    Ok(Ok(mut data)) => {
                                        for c in &mut contents {
                                            if c.next_raw {
                                                // No need to check the length because sum(content_len) == data.len().
                                                c.content = data.split_to(c.content_len).into();
                                            }
                                        }
                                    }
                                    Ok(Err(e)) => {
                                        // reset by peer
                                        self.stream = None;
                                        bail!("failed to get raw clipboard data: {}", e);
                                    }
                                    Err(e) => {
                                        // Reconnect to avoid the next raw data remaining in the buffer.
                                        self.stream = None;
                                        log::debug!("Failed to get raw clipboard data: {}", e);
                                    }
                                }
                            }
                            return Ok(contents);
                        }
                    }
                    Some(Data::ClipboardFile(ClipboardFile::MonitorReady)) => {
                        // ClipboardFile::MonitorReady is the first message sent by cm.
                    }
                    _ => {
                        bail!("failed to get clipboard data from cm");
                    }
                }
            }
        }
        // unreachable!
        bail!("failed to get clipboard data from cm");
    }
}

#[cfg(target_os = "android")]
fn run(sp: EmptyExtraFieldService) -> ResultType<()> {
    CLIPBOARD_SERVICE_OK.store(sp.ok(), Ordering::SeqCst);
    while sp.ok() {
        if let Some(msg) = crate::clipboard::get_clipboards_msg(false) {
            sp.send(msg);
        }
        std::thread::sleep(Duration::from_millis(INTERVAL));
    }
    CLIPBOARD_SERVICE_OK.store(false, Ordering::SeqCst);
    Ok(())
}
