#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

use clap::{Parser, Subcommand, ValueEnum};
use hbb_common::config::{self, Config};
#[cfg(target_os = "windows")]
use librustdesk::platform;
use librustdesk::{
    common, flutter_ffi, is_rendezvous_registered, portable_service, start_server, VERSION,
};
use reqwest::blocking::Client;
use serde::Deserialize;
use serde_json::json;
use std::collections::HashSet;
use std::fs::{create_dir_all, remove_dir, remove_file, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::{atomic::AtomicBool, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[cfg(target_os = "windows")]
use std::ffi::c_void;
#[cfg(target_os = "windows")]
use std::os::windows::ffi::OsStrExt;
#[cfg(target_os = "windows")]
use std::process::Command;
#[cfg(target_os = "windows")]
use std::sync::atomic::{AtomicIsize, Ordering};
#[cfg(target_os = "windows")]
use windows::core::PCWSTR;
#[cfg(target_os = "windows")]
use windows::Win32::Foundation::{COLORREF, HGLOBAL, HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
#[cfg(target_os = "windows")]
use windows::Win32::Graphics::Gdi::{
    CreateSolidBrush, GetStockObject, GetSysColor, GetSysColorBrush, SetBkMode, SetTextColor,
    COLOR_WINDOW, COLOR_WINDOWTEXT, DEFAULT_GUI_FONT, HDC, TRANSPARENT,
};
#[cfg(target_os = "windows")]
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, GetClipboardData, OpenClipboard,
};
#[cfg(target_os = "windows")]
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
#[cfg(target_os = "windows")]
use windows::Win32::System::Memory::{GlobalLock, GlobalSize, GlobalUnlock};
#[cfg(target_os = "windows")]
use windows::Win32::UI::Shell::{
    IsUserAnAdmin, Shell_NotifyIconW, NIF_ICON, NIF_TIP, NIM_ADD, NIM_DELETE, NOTIFYICONDATAW,
};
#[cfg(target_os = "windows")]
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DispatchMessageW, GetMessageW, GetSystemMetrics, IsWindow,
    LoadCursorW, LoadIconW, MessageBoxW, MoveWindow, PostMessageW, PostQuitMessage, RegisterClassW,
    SendMessageW, SetWindowTextW, ShowWindow, TranslateMessage, IDC_ARROW, IDI_APPLICATION, IDYES,
    MB_ICONERROR, MB_ICONINFORMATION, MB_ICONQUESTION, MB_OK, MB_SETFOREGROUND, MB_TOPMOST,
    MB_YESNO, MB_DEFBUTTON2, MSG, SM_CXSCREEN, SM_CYSCREEN, SW_MINIMIZE, SW_SHOW, WINDOW_EX_STYLE, WINDOW_STYLE,
    WM_CLOSE, WM_CTLCOLORSTATIC, WM_DESTROY, WM_SETFONT, WNDCLASSW, WS_CAPTION, WS_CHILD,
    WS_MINIMIZEBOX, WS_OVERLAPPED, WS_SYSMENU, WS_VISIBLE,
};
const DEFAULT_CERT_VERIFY_URL: &str = "https://admin.787.kr/api/certno/verify";
const DEFAULT_AGENTNUMUPDATE_BASE_URL: &str = "https://787.kr";
const DEFAULT_API_HINT: &str = "https://admin.787.kr";
// Cleanup-only values from the temporary internal-network build. These are never
// selected as endpoints and can only be used to remove the exact stale settings.
const ROLLED_BACK_PRIVATE_ID_SERVER: &str = "172.16.100.100:21116";
const ROLLED_BACK_PRIVATE_RELAY_SERVER: &str = "172.16.100.100:21117";
const READINESS_HTTP_TIMEOUT: Duration = Duration::from_secs(4);
const RENDEZVOUS_READY_POLL_INTERVAL: Duration = Duration::from_millis(100);
#[cfg(target_os = "windows")]
const WAITING_WINDOW_WIDTH: i32 = 360;
#[cfg(target_os = "windows")]
const WAITING_WINDOW_HEIGHT: i32 = 132;
#[cfg(target_os = "windows")]
const STATIC_STYLE_CENTER: u32 = 0x0000_0001;
#[cfg(target_os = "windows")]
const PROGRESS_X: i32 = 20;
#[cfg(target_os = "windows")]
const PROGRESS_Y: i32 = 82;
#[cfg(target_os = "windows")]
const PROGRESS_WIDTH: i32 = 320;
#[cfg(target_os = "windows")]
const PROGRESS_HEIGHT: i32 = 10;
#[cfg(target_os = "windows")]
const REMOTE_EXIT_IDLE_TICKS: u32 = 20;
#[cfg(target_os = "windows")]
const PORTABLE_SERVICE_READY_TIMEOUT: Duration = Duration::from_secs(10);
#[cfg(target_os = "windows")]
const INSTALLED_MDESK_READY_TIMEOUT: Duration = Duration::from_secs(20);
#[cfg(target_os = "windows")]
const INSTALLED_MDESK_READY_POLL_INTERVAL: Duration = Duration::from_millis(250);
#[cfg(target_os = "windows")]
const TRAY_ICON_ID: u32 = 1;
#[cfg(target_os = "windows")]
const APP_ICON_RESOURCE_ID: usize = 1;
#[cfg(target_os = "windows")]
static PROGRESS_TRACK_HWND: AtomicIsize = AtomicIsize::new(0);
#[cfg(target_os = "windows")]
static PROGRESS_FILL_HWND: AtomicIsize = AtomicIsize::new(0);
#[cfg(target_os = "windows")]
static PROGRESS_TRACK_BRUSH: AtomicIsize = AtomicIsize::new(0);
#[cfg(target_os = "windows")]
static PROGRESS_FILL_BRUSH: AtomicIsize = AtomicIsize::new(0);

const DIAGNOSTIC_LOG_FILE: &str = "MDeskMini_diagnostic.log";
const DIAGNOSTIC_LOG_FILTER: &str = "debug,reqwest=warn,rustls=warn,webrtc-sctp=warn,webrtc=warn";
static DIAGNOSTIC_LOG_PATH: OnceLock<Option<PathBuf>> = OnceLock::new();
static DIAGNOSTIC_STARTED_AT: OnceLock<Instant> = OnceLock::new();
static DIAGNOSTIC_LOG_LOCK: Mutex<()> = Mutex::new(());
static INTERNAL_FILE_LOGGER: OnceLock<hbb_common::flexi_logger::LoggerHandle> = OnceLock::new();
static LOG_CLEANUP_STARTED: AtomicBool = AtomicBool::new(false);

#[cfg(target_os = "windows")]
#[repr(C)]
#[derive(Default)]
struct DiagnosticSystemTime {
    year: u16,
    month: u16,
    day_of_week: u16,
    day: u16,
    hour: u16,
    minute: u16,
    second: u16,
    milliseconds: u16,
}

#[cfg(target_os = "windows")]
unsafe extern "system" {
    fn GetLocalTime(system_time: *mut DiagnosticSystemTime);
}

#[derive(Parser)]
#[command(name = "mdeskmini", about = "Minimal certificate-based host runtime")]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    /// Start host server
    Serve {
        /// Disable popup approval UI loop
        #[arg(long, default_value_t = false)]
        headless: bool,
        /// Host approval policy; auto accepts after certificate bootstrap
        #[arg(long, value_enum, default_value_t = ApproveModeArg::Auto)]
        approve_mode: ApproveModeArg,
        /// Permanent password to preset on host
        #[arg(long)]
        password: Option<String>,
        /// API base URL (ex: https://admin.787.kr)
        #[arg(long)]
        api: Option<String>,
    },
    /// Print host ID
    Id,
    /// Print build version
    Version,
    /// Ask the active controller to open file transfer at this file or folder
    SendToController {
        /// Selected Explorer path
        path: String,
    },
}

#[derive(Debug, Clone)]
struct ServeOptions {
    headless: bool,
    approve_mode: ApproveModeArg,
    password: Option<String>,
    api: Option<String>,
}

impl Default for ServeOptions {
    fn default() -> Self {
        Self {
            headless: false,
            approve_mode: ApproveModeArg::Auto,
            password: None,
            api: Some(DEFAULT_API_HINT.to_owned()),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
enum ApproveModeArg {
    Auto,
    Password,
    Click,
    Both,
}

impl ApproveModeArg {
    fn as_config_value(self) -> &'static str {
        match self {
            // Automatic acceptance is handled only by Mini, never by the core server.
            ApproveModeArg::Auto => "click",
            ApproveModeArg::Password => "password",
            ApproveModeArg::Click => "click",
            ApproveModeArg::Both => "both",
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
struct CmClient {
    id: i32,
    #[serde(default)]
    authorized: bool,
    #[serde(default)]
    disconnected: bool,
    #[serde(default)]
    peer_id: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    ip: String,
}

#[derive(Debug, Clone, Deserialize)]
struct CertVerifyResponse {
    #[serde(default)]
    success: bool,
    #[serde(default)]
    customer_id: String,
    #[serde(default)]
    peer_id: String,
    #[serde(default)]
    mdesk_id: String,
    #[serde(default)]
    owner_mdesk_id: String,
    #[serde(default)]
    session_id: i64,
    #[serde(default)]
    connection_token: String,
    #[serde(default)]
    message: String,
}

#[derive(Debug, Clone)]
struct CertVerification {
    verify_url: String,
    peer_id: String,
    customer_id: String,
    verified_peer_id: String,
    owner_mdesk_id: String,
    session_id: i64,
    connection_token: String,
}

fn main() {
    let _secure_log_cleanup = SecureLogCleanup;
    common::mark_mdeskmini_process_tree();
    // Applies before internal --server/--cm dispatch too, without changing the
    // installed client's preferences or the existing installed-MDesk handoff.
    config::require_websocket_for_process();
    let first_arg = std::env::args().nth(1);
    let delegates_to_core_main = is_rustdesk_internal_arg(first_arg.as_deref())
        || internal_mode_from_arg(first_arg.as_deref()).is_some();
    if !delegates_to_core_main {
        init_diagnostic_logging();
        diagnostic_event(
            "process.start",
            &format!(
                "version={VERSION} pid={} arch={} mode={}",
                std::process::id(),
                std::env::consts::ARCH,
                first_arg.as_deref().unwrap_or("serve")
            ),
        );
    }

    #[cfg(target_os = "windows")]
    {
        let elevated = is_running_as_administrator();
        if !delegates_to_core_main {
            diagnostic_event(
                "process.elevation",
                &format!("required=true elevated={elevated}"),
            );
        }
        if !elevated {
            if !delegates_to_core_main {
                diagnostic_event(
                    "process.elevation_failed",
                    "administrator token is required; refusing non-elevated startup",
                );
                show_error_popup(
                    "MDeskMini",
                    "MDeskMini는 관리자 권한으로만 실행할 수 있습니다.\nUAC 요청을 승인한 뒤 다시 실행해 주세요.",
                );
            }
            secure_process_exit(1);
        }
    }

    #[cfg(target_os = "windows")]
    {
        if !delegates_to_core_main {
            diagnostic_event("process.dpi.begin", "configuring DPI awareness");
        }
        enable_per_monitor_dpi_awareness();
        if !delegates_to_core_main {
            diagnostic_event("process.dpi.complete", "DPI awareness configured");
        }
    }

    if is_rustdesk_internal_arg(first_arg.as_deref()) {
        let _ = librustdesk::core_main::core_main();
        return;
    }

    if let Some(mode) = internal_mode_from_arg(first_arg.as_deref()) {
        match mode {
            InternalMode::Whiteboard => run_whiteboard_mode(),
        }
        return;
    }

    if first_arg.as_deref() == Some("--send-to-controller") {
        let args = std::env::args().collect::<Vec<_>>();
        let path = args.get(2).cloned().unwrap_or_default();
        let select_path = args.iter().any(|arg| arg == "--select");
        run_send_to_controller(path, select_path, false);
        return;
    }

    let cli = match Cli::try_parse() {
        Ok(cli) => cli,
        Err(err) => {
            eprintln!("{err}");
            secure_process_exit(err.exit_code());
        }
    };

    match cli.command {
        Some(Commands::Serve {
            headless,
            approve_mode,
            password,
            api,
        }) => run_serve(ServeOptions {
            headless,
            approve_mode,
            password,
            api: api.or_else(|| Some(DEFAULT_API_HINT.to_owned())),
        }),
        Some(Commands::Id) => run_id(),
        Some(Commands::Version) => println!("{VERSION}"),
        Some(Commands::SendToController { path }) => run_send_to_controller(path, false, false),
        None => run_serve(ServeOptions::default()),
    }
}

#[cfg(target_os = "windows")]
fn is_running_as_administrator() -> bool {
    unsafe { IsUserAnAdmin().as_bool() }
}

fn init_diagnostic_logging() {
    librustdesk::connection_diagnostics::event("mini", "", "process.version", &[
        ("build", env!("CARGO_PKG_VERSION")),
    ]);
    let _ = DIAGNOSTIC_STARTED_AT.set(Instant::now());
    let path = diagnostic_log_path();

    if let Some(directory) = path.as_ref().and_then(|path| path.parent()) {
        std::env::set_var("HBB_LOG_DIR", directory);
    }
    std::env::set_var("RUST_LOG", DIAGNOSTIC_LOG_FILTER);

    let default_panic_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |panic_info| {
        diagnostic_event("process.panic", &panic_info.to_string());
        default_panic_hook(panic_info);
        cleanup_mdeskmini_logs();
    }));

    diagnostic_event(
        "log.bootstrap",
        &format!(
            "diagnostic_log={}",
            path.as_ref()
                .map(|path| path.display().to_string())
                .unwrap_or_else(|| "unavailable".to_owned())
        ),
    );
    let internal_file_logger_ready = match hbb_common::init_log(false, "") {
        Some(handle) => INTERNAL_FILE_LOGGER.set(handle).is_ok(),
        None => false,
    };
    if let Some(path) = path {
        diagnostic_event(
            "log.ready",
            &format!(
                "diagnostic_log={} internal_file_logger_ready={internal_file_logger_ready} max_level={:?}",
                path.display(),
                hbb_common::log::max_level()
            ),
        );
    } else {
        hbb_common::log::error!("[MDeskMini][log.failed] no writable diagnostic log path");
    }
}

struct SecureLogCleanup;

impl Drop for SecureLogCleanup {
    fn drop(&mut self) {
        cleanup_mdeskmini_logs();
    }
}

fn secure_process_exit(code: i32) -> ! {
    cleanup_mdeskmini_logs();
    std::process::exit(code)
}

fn cleanup_mdeskmini_logs() {
    // The separate, sanitized connection timeline survives normal log cleanup.
    librustdesk::connection_diagnostics::flush();
    if LOG_CLEANUP_STARTED.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return;
    }

    let is_primary_process = DIAGNOSTIC_STARTED_AT.get().is_some();
    let mut log_files = hbb_common::shutdown_log_and_get_files();
    let mut helper_directories = Vec::new();

    if is_primary_process {
        if let Some(Some(path)) = DIAGNOSTIC_LOG_PATH.get() {
            log_files.push(path.clone());
        }

        if let Ok(exe) = std::env::current_exe() {
            if let Some(directory) = exe.parent() {
                collect_mdeskmini_log_files(directory, &mut log_files);
                for helper_name in ["portable-service", "elevate", "run-as-system", "whiteboard"] {
                    let helper_directory = directory.join(helper_name);
                    collect_mdeskmini_log_files(&helper_directory, &mut log_files);
                    helper_directories.push(helper_directory);
                }
            }
        }
    }

    let mut unique_files = HashSet::new();
    log_files.retain(|path| unique_files.insert(path.clone()));

    for _ in 0..5 {
        log_files.retain(|path| match remove_file(path) {
            Ok(()) => false,
            Err(_) => path.exists(),
        });
        if log_files.is_empty() {
            break;
        }
        thread::sleep(Duration::from_millis(100));
    }

    for directory in helper_directories {
        let _ = remove_dir(directory);
    }
}

fn collect_mdeskmini_log_files(directory: &std::path::Path, output: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return;
    };

    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_file() && is_mdeskmini_log_file_name(&entry.file_name().to_string_lossy()) {
            output.push(path);
        }
    }
}

fn is_mdeskmini_log_file_name(file_name: &str) -> bool {
    let file_name = file_name.to_ascii_lowercase();
    file_name == DIAGNOSTIC_LOG_FILE.to_ascii_lowercase()
        || (file_name.starts_with("mdeskmini")
            && (file_name.ends_with(".log") || file_name.ends_with(".gz")))
}

fn diagnostic_log_path() -> Option<PathBuf> {
    DIAGNOSTIC_LOG_PATH
        .get_or_init(|| {
            let mut directories = Vec::new();
            if let Ok(exe) = std::env::current_exe() {
                if let Some(parent) = exe.parent() {
                    directories.push(parent.to_path_buf());
                }
            }
            directories.push(Config::log_path());
            directories.push(std::env::temp_dir().join("MDesk"));

            for directory in directories {
                if directory.as_os_str().is_empty() || create_dir_all(&directory).is_err() {
                    continue;
                }
                let path = directory.join(DIAGNOSTIC_LOG_FILE);
                if OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&path)
                    .is_ok()
                {
                    return Some(path);
                }
            }
            None
        })
        .clone()
}

fn diagnostic_event(stage: &str, detail: &str) {
    // Do not copy `detail`: legacy diagnostics can contain URLs/session tokens.
    let stage_ms = detail.split_whitespace()
        .find_map(|v| v.strip_prefix("elapsed_ms=").and_then(|v| v.parse::<u128>().ok()));
    let status = detail.split_whitespace()
        .find_map(|v| v.strip_prefix("status=").and_then(|v| v.parse::<u16>().ok()));
    let progress = detail.split_whitespace()
        .find_map(|v| v.strip_prefix("percent=").and_then(|v| v.parse::<u8>().ok()));
    let peer = detail.split_whitespace().find_map(|v| {
        v.strip_prefix("verified_peer_id=").or_else(|| v.strip_prefix("local_peer_id="))
            .or_else(|| v.strip_prefix("peer_id="))
    }).unwrap_or_default();
    librustdesk::connection_diagnostics::event("mini", "", stage, &[
        ("registered", if is_rendezvous_registered() { "true" } else { "false" }),
        ("duration_ms", &stage_ms.map(|v| v.to_string()).unwrap_or_default()),
        ("status", &status.map(|v| v.to_string()).unwrap_or_default()),
        ("progress", &progress.map(|v| v.to_string()).unwrap_or_default()),
        ("peer", peer),
        ("reason", if stage.contains("failed") || stage.contains("error") {
            librustdesk::connection_diagnostics::error_kind(detail)
        } else { "" }),
    ]);
    let elapsed_ms = DIAGNOSTIC_STARTED_AT
        .get()
        .map(|started| started.elapsed().as_millis())
        .unwrap_or(0);
    let epoch_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or(0);
    let detail = detail.replace(['\r', '\n'], " ");
    let line = format!(
        "time={} epoch_ms={epoch_ms} elapsed_ms={elapsed_ms} pid={} stage={stage} {detail}",
        diagnostic_local_time(),
        std::process::id()
    );

    if let Ok(_guard) = DIAGNOSTIC_LOG_LOCK.lock() {
        if let Some(path) = diagnostic_log_path() {
            if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
                if file
                    .metadata()
                    .map(|metadata| metadata.len() == 0)
                    .unwrap_or(false)
                {
                    let _ = file.write_all(&[0xEF, 0xBB, 0xBF]);
                }
                let _ = writeln!(file, "{line}");
                let _ = file.flush();
            }
        }
    }
    hbb_common::log::info!("[MDeskMini][{stage}] {detail}");
    hbb_common::log::logger().flush();
}

#[cfg(target_os = "windows")]
fn diagnostic_local_time() -> String {
    let mut value = DiagnosticSystemTime::default();
    unsafe { GetLocalTime(&mut value) };
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}",
        value.year,
        value.month,
        value.day,
        value.hour,
        value.minute,
        value.second,
        value.milliseconds
    )
}

#[cfg(not(target_os = "windows"))]
fn diagnostic_local_time() -> String {
    "local-time-unavailable".to_owned()
}

#[cfg(target_os = "windows")]
fn enable_per_monitor_dpi_awareness() {
    type SetProcessDpiAwarenessContextFn = unsafe extern "system" fn(isize) -> i32;
    type SetProcessDpiAwarenessFn = unsafe extern "system" fn(i32) -> i32;
    type SetProcessDpiAwareFn = unsafe extern "system" fn() -> i32;

    unsafe extern "system" {
        fn LoadLibraryW(file_name: *const u16) -> *mut c_void;
        fn GetProcAddress(module: *mut c_void, proc_name: *const u8) -> *mut c_void;
    }

    unsafe fn load_proc(dll_name: &str, proc_name: &'static [u8]) -> *mut c_void {
        let dll_name: Vec<u16> = dll_name.encode_utf16().chain(std::iter::once(0)).collect();
        let module = unsafe { LoadLibraryW(dll_name.as_ptr()) };
        if module.is_null() {
            return std::ptr::null_mut();
        }
        unsafe { GetProcAddress(module, proc_name.as_ptr()) }
    }

    // Keep coordinates in physical pixels. Resolve newer DPI APIs at runtime
    // so the executable loader can still start on Windows 7.
    let proc = unsafe { load_proc("user32.dll", b"SetProcessDpiAwarenessContext\0") };
    if !proc.is_null() {
        let set_context: SetProcessDpiAwarenessContextFn = unsafe { std::mem::transmute(proc) };
        const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;
        if unsafe { set_context(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) } != 0 {
            return;
        }
    }

    let proc = unsafe { load_proc("shcore.dll", b"SetProcessDpiAwareness\0") };
    if !proc.is_null() {
        let set_awareness: SetProcessDpiAwarenessFn = unsafe { std::mem::transmute(proc) };
        const PROCESS_PER_MONITOR_DPI_AWARE: i32 = 2;
        if unsafe { set_awareness(PROCESS_PER_MONITOR_DPI_AWARE) } >= 0 {
            return;
        }
    }

    let proc = unsafe { load_proc("user32.dll", b"SetProcessDPIAware\0") };
    if !proc.is_null() {
        let set_aware: SetProcessDpiAwareFn = unsafe { std::mem::transmute(proc) };
        let _ = unsafe { set_aware() };
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum InternalMode {
    Whiteboard,
}

fn internal_mode_from_arg(arg: Option<&str>) -> Option<InternalMode> {
    match arg {
        Some("--whiteboard") => Some(InternalMode::Whiteboard),
        _ => None,
    }
}

fn is_rustdesk_internal_arg(arg: Option<&str>) -> bool {
    matches!(
        arg,
        Some("--portable-service" | "--elevate" | "--run-as-system")
    )
}

fn run_whiteboard_mode() {
    // Whiteboard worker process is launched by host runtime via current exe + `--whiteboard`.
    // Delegate to upstream core_main handler to keep behavior aligned with the main project.
    let _ = librustdesk::core_main::core_main();
}

fn run_id() {
    if !init_runtime() {
        secure_process_exit(1);
    }
    println!("{}", Config::get_id());
    common::global_clean();
}

fn run_send_to_controller(path: String, select_path: bool, show_errors: bool) {
    #[cfg(target_os = "windows")]
    {
        if !init_runtime() {
            if show_errors {
                show_error_popup("MDeskMini", "Failed to initialize MDeskMini.");
            }
            secure_process_exit(1);
        }

        let result = run_send_to_controller_windows(path, select_path);
        common::global_clean();

        if let Err(err) = result {
            eprintln!("failed to request file transfer from Explorer: {err}");
            if show_errors {
                show_error_popup("MDeskMini", &err);
            }
            secure_process_exit(1);
        }
    }

    #[cfg(not(target_os = "windows"))]
    {
        let _ = (path, select_path, show_errors);
        eprintln!("send-to-controller is only supported on Windows.");
        secure_process_exit(1);
    }
}

#[cfg(target_os = "windows")]
fn run_send_to_controller_windows(path: String, select_path: bool) -> Result<(), String> {
    platform::send_explorer_path_to_controller(path, select_path)
}

fn run_serve(options: ServeOptions) {
    diagnostic_event(
        "serve.begin",
        &format!(
            "headless={} approve_mode={:?} api_configured={} password_configured={}",
            options.headless,
            options.approve_mode,
            options
                .api
                .as_deref()
                .is_some_and(|value| !value.trim().is_empty()),
            options
                .password
                .as_deref()
                .is_some_and(|value| !value.trim().is_empty())
        ),
    );
    #[cfg(target_os = "windows")]
    let mut waiting_window = if options.headless {
        None
    } else {
        WaitingWindow::spawn()
    };
    #[cfg(target_os = "windows")]
    diagnostic_event(
        "ui.waiting_window",
        if options.headless {
            "disabled by headless mode"
        } else if waiting_window.is_some() {
            "created"
        } else {
            "creation failed"
        },
    );
    #[cfg(target_os = "windows")]
    update_startup_progress(
        waiting_window.as_ref(),
        5,
        "MDesk 준비중",
        "프로그램을 초기화하고 있습니다.",
    );

    if !init_runtime_for_serve() {
        diagnostic_event("runtime.failed", "serve runtime initialization failed");
        #[cfg(target_os = "windows")]
        update_startup_progress(
            waiting_window.as_ref(),
            100,
            "MDesk 준비 실패",
            "초기화에 실패했습니다.",
        );
        secure_process_exit(1);
    }
    diagnostic_event(
        "runtime.ready",
        &format!("local_peer_id={}", Config::get_id()),
    );

    #[cfg(target_os = "windows")]
    if let Some(installed_exe) = installed_mdesk_executable() {
        diagnostic_event("installed_mdesk.detected", &format!("path={installed_exe}"));
        let result = run_installed_mdesk_handoff(&options, waiting_window.as_ref(), &installed_exe);
        if let Err(err) = result {
            diagnostic_event("installed_mdesk.handoff_failed", &err);
            eprintln!("installed MDesk handoff failed: {err}");
            update_startup_progress(
                waiting_window.as_ref(),
                100,
                "MDesk 연결 준비 실패",
                "설치된 MDesk의 원격 준비 상태를 확인하지 못했습니다.",
            );
            show_error_popup(
                "MDeskMini",
                &format!(
                    "설치된 MDesk를 실행했지만 원격 연결 준비를 완료하지 못했습니다.\n\n{err}"
                ),
            );
        }
        if let Some(window) = waiting_window.take() {
            window.close();
        }
        common::global_clean();
        diagnostic_event("process.exit", "installed MDesk handoff path completed");
        return;
    }
    diagnostic_event(
        "installed_mdesk.not_found",
        "continuing in portable host mode",
    );

    #[cfg(target_os = "windows")]
    platform::unregister_explorer_send_to_controller_menu();

    #[cfg(target_os = "windows")]
    update_startup_progress(
        waiting_window.as_ref(),
        30,
        "MDesk 준비중",
        "원격 접속 정책을 적용하고 있습니다.",
    );

    #[cfg(target_os = "windows")]
    update_startup_progress(
        waiting_window.as_ref(),
        45,
        "MDesk 준비중",
        "인증번호를 확인하고 있습니다.",
    );
    let cert_verification = match require_certificate(apply_clipboard_cert_bootstrap(&options)) {
        Ok(verification) => Some(verification),
        Err(err) => {
            diagnostic_event("cert.bootstrap_failed", &err);
            #[cfg(target_os = "windows")]
            show_error_popup("MDeskMini", "Certificate verification failed. Remote access was not started.");
            common::global_clean();
            secure_process_exit(1);
        }
    };
    let certificate_verified = cert_verification.is_some();
    apply_host_policy(&options);
    diagnostic_event("policy.applied", "host acceptance policy applied");
    if let Some(verification) = cert_verification.clone() {
        report_readiness_stage_async(
            verification,
            options.api.clone().unwrap_or_default(),
            "preparing",
        );
    }

    #[cfg(target_os = "windows")]
    update_startup_progress(
        waiting_window.as_ref(),
        60,
        "MDesk 준비중",
        "원격 연결 허용 상태를 준비하고 있습니다.",
    );
    ensure_host_accepting_mode();
    diagnostic_event("host.accepting", "host accepting mode is enabled");

    #[cfg(target_os = "windows")]
    match ensure_portable_service_ready() {
        Ok(()) => {
            println!("SYSTEM portable service is ready");
            diagnostic_event("portable_service.ready", "SYSTEM portable service is ready");
        }
        Err(err) => {
            eprintln!("failed to prepare SYSTEM portable service; continuing without it: {err}");
            diagnostic_event("portable_service.failed", &err);
        }
    }

    println!("starting mdeskmini host server");
    println!("version={VERSION}");
    println!("id={}", Config::get_id());

    #[cfg(target_os = "windows")]
    update_startup_progress(
        waiting_window.as_ref(),
        72,
        "MDesk 준비중",
        "연결 관리자를 시작하고 있습니다.",
    );
    flutter_ffi::cm_init();
    diagnostic_event("connection_manager.ready", "connection manager initialized");
    if let Some(verification) = cert_verification.clone() {
        report_readiness_stage_async(
            verification,
            options.api.clone().unwrap_or_default(),
            "service_ready",
        );
    }

    #[cfg(target_os = "windows")]
    update_startup_progress(
        waiting_window.as_ref(),
        82,
        "MDesk 준비중",
        "작업 표시줄 아이콘을 준비하고 있습니다.",
    );
    #[cfg(target_os = "windows")]
    let tray_icon = TrayIcon::spawn();
    #[cfg(target_os = "windows")]
    diagnostic_event(
        "tray.ready",
        if tray_icon.is_some() {
            "tray icon created"
        } else {
            "tray icon creation failed"
        },
    );

    #[cfg(target_os = "windows")]
    update_startup_progress(
        waiting_window.as_ref(),
        92,
        "MDesk 준비중",
        "원격 서버를 시작하고 있습니다.",
    );
    diagnostic_event("server.spawn", "starting host server thread");
    diagnostic_event(
        "audit.capability",
        "connection_intent_v2=true reporter_login_required=false",
    );
    let server_thread = thread::spawn(|| {
        diagnostic_event("server.thread.begin", "host server thread entered");
        start_server(true, false);
        diagnostic_event("server.thread.exit", "host server thread returned");
    });
    if let Some(verification) = cert_verification {
        diagnostic_event(
            "rendezvous.reporter_spawn",
            &format!("peer_id={}", verification.verified_peer_id),
        );
        spawn_rendezvous_ready_reporter(verification, options.api.clone().unwrap_or_default());
    }

    #[cfg(target_os = "windows")]
    update_startup_progress(
        waiting_window.as_ref(),
        100,
        "MDesk 원격대기중",
        "원격 연결 요청을 기다리는 중입니다.",
    );

    if !options.headless {
        monitor_pending_connections(
            &server_thread,
            waiting_window.as_ref(),
            options.approve_mode,
            certificate_verified,
        );
    }

    let _ = server_thread.join();
    diagnostic_event("server.joined", "host server thread joined");
    #[cfg(target_os = "windows")]
    platform::unregister_explorer_send_to_controller_menu();
    #[cfg(target_os = "windows")]
    if let Some(window) = waiting_window.take() {
        window.close();
    }
    #[cfg(target_os = "windows")]
    if let Some(tray_icon) = tray_icon {
        tray_icon.close();
    }
    common::global_clean();
    diagnostic_event("process.exit", "MDeskMini serve completed");
}

#[cfg(target_os = "windows")]
fn update_startup_progress(
    waiting_window: Option<&WaitingWindow>,
    percent: u8,
    title: &str,
    body: &str,
) {
    diagnostic_event(
        "startup.progress",
        &format!("percent={percent} title={title} message={body}"),
    );
    if let Some(window) = waiting_window {
        window.set_progress(title, body, percent);
    }
}

fn init_runtime() -> bool {
    diagnostic_event(
        "runtime.global_init.begin",
        "starting global initialization",
    );
    if common::global_init() {
        diagnostic_event(
            "runtime.global_init.complete",
            "global initialization completed",
        );
        true
    } else {
        eprintln!("global initialization failed");
        diagnostic_event(
            "runtime.global_init.failed",
            "global initialization returned false",
        );
        false
    }
}

fn init_runtime_for_serve() -> bool {
    if !init_runtime() {
        return false;
    }

    diagnostic_event(
        "runtime.custom_client.begin",
        "loading custom client settings",
    );
    common::load_custom_client();
    diagnostic_event(
        "runtime.custom_client.complete",
        "custom client settings loaded",
    );
    config::apply_product_default_settings();
    diagnostic_event("runtime.defaults.complete", "product defaults applied");

    #[cfg(target_os = "windows")]
    if !platform::windows::bootstrap() {
        eprintln!("windows bootstrap failed");
        diagnostic_event(
            "runtime.windows_bootstrap.failed",
            "Windows bootstrap returned false",
        );
        return false;
    }
    #[cfg(target_os = "windows")]
    diagnostic_event(
        "runtime.windows_bootstrap.complete",
        "Windows bootstrap completed",
    );

    true
}

#[cfg(target_os = "windows")]
fn installed_mdesk_executable() -> Option<String> {
    let (_, _, _, installed_exe) = platform::windows::get_install_info();
    let installed_path = std::path::Path::new(&installed_exe);
    if !installed_path.is_file() {
        return None;
    }

    let current_exe = std::env::current_exe().ok()?;
    if same_windows_path(installed_path, &current_exe) {
        return None;
    }

    Some(installed_exe)
}

#[cfg(target_os = "windows")]
fn same_windows_path(left: &std::path::Path, right: &std::path::Path) -> bool {
    let left = left.canonicalize().unwrap_or_else(|_| left.to_path_buf());
    let right = right.canonicalize().unwrap_or_else(|_| right.to_path_buf());
    left.to_string_lossy()
        .eq_ignore_ascii_case(&right.to_string_lossy())
}

#[cfg(target_os = "windows")]
fn run_installed_mdesk_handoff(
    options: &ServeOptions,
    waiting_window: Option<&WaitingWindow>,
    installed_exe: &str,
) -> Result<(), String> {
    diagnostic_event(
        "installed_mdesk.handoff_begin",
        &format!("path={installed_exe}"),
    );
    update_startup_progress(
        waiting_window,
        15,
        "설치된 MDesk 확인",
        "설치된 MDesk를 사용하여 원격 연결을 준비합니다.",
    );
    let verification = require_certificate(apply_clipboard_cert_bootstrap(options))?;
    show_information_popup(
        "MDeskMini",
        "MDesk가 이미 설치되어 있습니다.\n설치된 MDesk를 실행하여 원격 연결을 준비합니다.",
    );

    Command::new(installed_exe)
        .env_remove(common::MDESKMINI_PROCESS_MARKER_ENV)
        .env_remove(common::MDESKMINI_FIREWALL_BOOTSTRAPPED_ENV)
        .spawn()
        .map_err(|err| format!("설치된 MDesk를 실행할 수 없습니다: {err}"))?;
    diagnostic_event("installed_mdesk.spawned", "installed MDesk process spawned");

    update_startup_progress(
        waiting_window,
        30,
        "설치된 MDesk 실행 중",
        "인증번호와 원격 연결 정책을 확인하고 있습니다.",
    );
    apply_host_policy(options);
    report_readiness_stage(
        &verification,
        options.api.as_deref().unwrap_or_default(),
        "preparing",
    )?;

    ensure_host_accepting_mode();
    update_startup_progress(
        waiting_window,
        55,
        "설치된 MDesk 연결 중",
        "설치된 서비스가 응답할 때까지 기다리고 있습니다.",
    );

    wait_for_installed_mdesk_ready(
        options,
        &verification,
        options.api.as_deref().unwrap_or_default(),
        waiting_window,
    )?;

    update_startup_progress(
        waiting_window,
        100,
        "원격 연결 준비 완료",
        "설치된 MDesk가 준비되었습니다. 원격 연결을 시작할 수 있습니다.",
    );
    thread::sleep(Duration::from_millis(700));
    diagnostic_event(
        "installed_mdesk.handoff_complete",
        "remote ready was reported",
    );
    Ok(())
}

#[cfg(target_os = "windows")]
fn wait_for_installed_mdesk_ready(
    options: &ServeOptions,
    verification: &CertVerification,
    api_hint: &str,
    waiting_window: Option<&WaitingWindow>,
) -> Result<(), String> {
    let runtime = hbb_common::tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|err| format!("설치된 MDesk 상태 확인기를 만들 수 없습니다: {err}"))?;
    let started_at = Instant::now();
    let mut configuration_synced = false;
    let mut service_reported = false;
    let mut last_status = "설치된 MDesk 서비스의 응답을 기다리는 중".to_owned();

    while started_at.elapsed() < INSTALLED_MDESK_READY_TIMEOUT {
        match query_installed_mdesk_online_status(&runtime) {
            Ok((online, confirmed)) => {
                diagnostic_event(
                    "installed_mdesk.status",
                    &format!(
                        "online={online} confirmed={confirmed} elapsed_ms={}",
                        started_at.elapsed().as_millis()
                    ),
                );
                if !configuration_synced {
                    match sync_installed_mdesk_host_config(&runtime, options) {
                        Ok(()) => {
                            configuration_synced = true;
                            diagnostic_event(
                                "installed_mdesk.config_synced",
                                "host configuration synchronized",
                            );
                        }
                        Err(err) => {
                            diagnostic_event("installed_mdesk.config_sync_failed", &err);
                            last_status = err;
                            thread::sleep(INSTALLED_MDESK_READY_POLL_INTERVAL);
                            continue;
                        }
                    }
                }

                if !service_reported {
                    report_readiness_stage(verification, api_hint, "service_ready")?;
                    service_reported = true;
                    update_startup_progress(
                        waiting_window,
                        75,
                        "설치된 MDesk 서비스 확인",
                        "원격 서버 등록이 완료될 때까지 기다리고 있습니다.",
                    );
                }

                last_status = format!("설치된 MDesk 상태: online={online}, confirmed={confirmed}");
                if online > 0 {
                    report_remote_ready(verification, api_hint)?;
                    println!(
                        "installed MDesk is online; remote ready reported: online={online} confirmed={confirmed}"
                    );
                    return Ok(());
                }
            }
            Err(err) => {
                diagnostic_event("installed_mdesk.status_error", &err);
                last_status = err;
            }
        }
        thread::sleep(INSTALLED_MDESK_READY_POLL_INTERVAL);
    }

    Err(format!(
        "{}초 동안 설치된 MDesk의 온라인 상태를 확인하지 못했습니다. 마지막 상태: {last_status}",
        INSTALLED_MDESK_READY_TIMEOUT.as_secs()
    ))
}

#[cfg(target_os = "windows")]
fn query_installed_mdesk_online_status(
    runtime: &hbb_common::tokio::runtime::Runtime,
) -> Result<(i64, bool), String> {
    runtime.block_on(async {
        let mut connection = librustdesk::ipc::connect(1_200, "")
            .await
            .map_err(|err| format!("설치된 MDesk 서비스에 연결할 수 없습니다: {err}"))?;
        connection
            .send(&librustdesk::ipc::Data::OnlineStatus(None))
            .await
            .map_err(|err| format!("설치된 MDesk에 상태 확인을 보낼 수 없습니다: {err}"))?;
        match connection
            .next_timeout(1_200)
            .await
            .map_err(|err| format!("설치된 MDesk 상태 응답을 받을 수 없습니다: {err}"))?
        {
            Some(librustdesk::ipc::Data::OnlineStatus(Some(status))) => Ok(status),
            Some(other) => Err(format!(
                "설치된 MDesk가 예상하지 못한 상태를 보냈습니다: {other:?}"
            )),
            None => Err("설치된 MDesk가 빈 상태 응답을 보냈습니다.".to_owned()),
        }
    })
}

#[cfg(target_os = "windows")]
fn sync_installed_mdesk_host_config(
    runtime: &hbb_common::tokio::runtime::Runtime,
    options: &ServeOptions,
) -> Result<(), String> {
    runtime.block_on(async {
        let mut connection = librustdesk::ipc::connect(1_200, "")
            .await
            .map_err(|err| format!("설치된 MDesk 설정 채널에 연결할 수 없습니다: {err}"))?;
        connection
            .send(&librustdesk::ipc::Data::Options(None))
            .await
            .map_err(|err| format!("설치된 MDesk 설정을 요청할 수 없습니다: {err}"))?;
        let mut installed_options = match connection
            .next_timeout(1_200)
            .await
            .map_err(|err| format!("설치된 MDesk 설정을 받을 수 없습니다: {err}"))?
        {
            Some(librustdesk::ipc::Data::Options(Some(options))) => options,
            Some(other) => {
                return Err(format!(
                    "설치된 MDesk가 예상하지 못한 설정 응답을 보냈습니다: {other:?}"
                ));
            }
            None => return Err("설치된 MDesk가 빈 설정 응답을 보냈습니다.".to_owned()),
        };

        for key in [
            "approve-mode",
            "api-server",
            "custom-certno",
            "custom-agentid",
            "custom-id",
            "stop-service",
            "verification-method",
        ] {
            let value = Config::get_option(key);
            if value.is_empty() {
                installed_options.remove(key);
            } else {
                installed_options.insert(key.to_owned(), value);
            }
        }

        connection
            .send(&librustdesk::ipc::Data::Options(Some(installed_options)))
            .await
            .map_err(|err| format!("설치된 MDesk 설정을 적용할 수 없습니다: {err}"))?;
        match connection
            .next_timeout(1_200)
            .await
            .map_err(|err| format!("설치된 MDesk 설정 적용 응답을 받을 수 없습니다: {err}"))?
        {
            Some(librustdesk::ipc::Data::Options(None)) => {}
            Some(other) => {
                return Err(format!(
                    "설치된 MDesk가 예상하지 못한 설정 적용 응답을 보냈습니다: {other:?}"
                ));
            }
            None => return Err("설치된 MDesk가 설정 적용을 확인하지 않았습니다.".to_owned()),
        }

        if let Some(password) = options.password.as_deref() {
            let password = password.trim();
            if !password.is_empty() {
                connection
                    .send(&librustdesk::ipc::Data::Config((
                        "permanent-password".to_owned(),
                        Some(password.to_owned()),
                    )))
                    .await
                    .map_err(|err| {
                        format!("설치된 MDesk에 원격 비밀번호를 적용할 수 없습니다: {err}")
                    })?;
            }
        }

        println!("installed MDesk host configuration synchronized");
        Ok(())
    })
}

fn is_rolled_back_private_server(current: &str, rolled_back: &str) -> bool {
    current.trim().eq_ignore_ascii_case(rolled_back)
}

fn clear_rolled_back_private_server_options() {
    for (key, rolled_back) in [
        ("custom-rendezvous-server", ROLLED_BACK_PRIVATE_ID_SERVER),
        ("relay-server", ROLLED_BACK_PRIVATE_RELAY_SERVER),
    ] {
        if is_rolled_back_private_server(&Config::get_option(key), rolled_back) {
            Config::set_option(key.to_owned(), String::new());
            diagnostic_event(
                "policy.rolled_back_endpoint_cleared",
                &format!("cleared stale option={key}"),
            );
        }
    }
}

fn apply_host_policy(options: &ServeOptions) {
    clear_rolled_back_private_server_options();
    Config::set_option(
        "approve-mode".to_owned(),
        options.approve_mode.as_config_value().to_owned(),
    );

    if let Some(password) = options.password.as_deref() {
        let trimmed = password.trim();
        if !trimmed.is_empty() {
            Config::set_permanent_password(trimmed);
            Config::set_option(
                "verification-method".to_owned(),
                "use-permanent-password".to_owned(),
            );
        }
    }

    if let Some(api) = options.api.as_deref() {
        let trimmed = api.trim().trim_end_matches('/');
        if !trimmed.is_empty() {
            Config::set_option("api-server".to_owned(), trimmed.to_owned());
        }
    }
}

fn apply_clipboard_cert_bootstrap(
    options: &ServeOptions,
) -> Result<Option<CertVerification>, String> {
    diagnostic_event(
        "cert.clipboard.begin",
        "checking clipboard for certificate number",
    );
    let Some(certnum) = clipboard_certnum() else {
        diagnostic_event("cert.clipboard.empty", "certificate number was not found");
        return Ok(None);
    };

    println!("clipboard certno detected");
    diagnostic_event(
        "cert.clipboard.detected",
        &format!("digit_count={}", certnum.len()),
    );

    match verify_cert_number(&certnum, options.api.as_deref().unwrap_or_default()) {
        Ok(verification) => {
            clear_clipboard_cert_if_matches(&certnum);
            Config::set_option("custom-certno".to_owned(), "true".to_owned());
            Config::set_option("custom-agentid".to_owned(), "0".to_owned());
            Config::set_option("custom-id".to_owned(), verification.customer_id.clone());
            println!(
                "cert verify success: customer_id={} peer_id={} verified_peer_id={} url={}",
                verification.customer_id,
                verification.peer_id,
                verification.verified_peer_id,
                verification.verify_url
            );
            diagnostic_event(
                "cert.verify.success",
                &format!(
                    "customer_id={} local_peer_id={} verified_peer_id={} session_id={} url={}",
                    verification.customer_id,
                    verification.peer_id,
                    verification.verified_peer_id,
                    verification.session_id,
                    verification.verify_url
                ),
            );
            Ok(Some(verification))
        }
        Err(err) => Err(err),
    }
}

fn clipboard_certnum() -> Option<String> {
    let clipboard_text = clipboard_text()?;
    extract_certnum_from_clipboard_text(&clipboard_text)
}

fn clipboard_text() -> Option<String> {
    #[cfg(target_os = "windows")]
    {
        read_windows_clipboard_text().ok()
    }
    #[cfg(not(target_os = "windows"))]
    {
        None
    }
}

fn clear_clipboard_cert_if_matches(expected_certnum: &str) {
    #[cfg(target_os = "windows")]
    {
        let is_same_cert = clipboard_text()
            .and_then(|text| extract_certnum_from_clipboard_text(&text))
            .map(|cert| cert == expected_certnum)
            .unwrap_or(false);
        if !is_same_cert {
            return;
        }
        match clear_windows_clipboard() {
            Ok(()) => {
                println!("clipboard certno cleared");
                diagnostic_event("cert.clipboard.cleared", "certificate number cleared");
            }
            Err(err) => {
                eprintln!("failed to clear clipboard certno: {err}");
                diagnostic_event("cert.clipboard.clear_failed", &err);
            }
        }
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = expected_certnum;
    }
}

#[cfg(target_os = "windows")]
fn clear_windows_clipboard() -> Result<(), String> {
    let _clipboard = open_windows_clipboard()?;
    unsafe { EmptyClipboard() }.map_err(|err| format!("EmptyClipboard failed: {err}"))
}

#[cfg(target_os = "windows")]
struct WindowsClipboardGuard;

#[cfg(target_os = "windows")]
impl Drop for WindowsClipboardGuard {
    fn drop(&mut self) {
        let _ = unsafe { CloseClipboard() };
    }
}

#[cfg(target_os = "windows")]
struct WindowsGlobalLockGuard(HGLOBAL);

#[cfg(target_os = "windows")]
impl Drop for WindowsGlobalLockGuard {
    fn drop(&mut self) {
        let _ = unsafe { GlobalUnlock(self.0) };
    }
}

#[cfg(target_os = "windows")]
fn open_windows_clipboard() -> Result<WindowsClipboardGuard, String> {
    let mut last_error = String::new();
    for attempt in 1..=20 {
        match unsafe { OpenClipboard(None) } {
            Ok(()) => return Ok(WindowsClipboardGuard),
            Err(err) => {
                last_error = err.to_string();
                if attempt < 20 {
                    thread::sleep(Duration::from_millis(25));
                }
            }
        }
    }
    Err(format!("OpenClipboard failed after retries: {last_error}"))
}

#[cfg(target_os = "windows")]
fn read_windows_clipboard_text() -> Result<String, String> {
    const CF_UNICODETEXT: u32 = 13;

    let _clipboard = open_windows_clipboard()?;
    let handle = unsafe { GetClipboardData(CF_UNICODETEXT) }
        .map_err(|err| format!("GetClipboardData(CF_UNICODETEXT) failed: {err}"))?;
    let global = HGLOBAL(handle.0);
    let byte_len = unsafe { GlobalSize(global) };
    if byte_len < std::mem::size_of::<u16>() {
        return Err("clipboard Unicode text is empty".to_owned());
    }

    let pointer = unsafe { GlobalLock(global) };
    if pointer.is_null() {
        return Err("GlobalLock failed for clipboard Unicode text".to_owned());
    }
    let _lock = WindowsGlobalLockGuard(global);
    let units = unsafe {
        std::slice::from_raw_parts(pointer.cast::<u16>(), byte_len / std::mem::size_of::<u16>())
    };
    decode_windows_clipboard_text(units)
}

fn decode_windows_clipboard_text(units: &[u16]) -> Result<String, String> {
    let end = units
        .iter()
        .position(|unit| *unit == 0)
        .unwrap_or(units.len());
    let text = String::from_utf16(&units[..end])
        .map_err(|err| format!("clipboard contains invalid UTF-16 text: {err}"))?
        .trim()
        .to_owned();
    if text.is_empty() {
        Err("clipboard Unicode text is empty".to_owned())
    } else {
        Ok(text)
    }
}

fn extract_certnum_from_clipboard_text(raw: &str) -> Option<String> {
    fn parse_one(text: &str) -> Option<String> {
        let text = text.trim();
        if text.is_empty() {
            return None;
        }

        let mut split = text.splitn(2, ':');
        let left = split.next()?.trim();
        let right = split.next()?.trim();
        if !left.eq_ignore_ascii_case("certno") {
            return None;
        }
        if right.is_empty() || !right.chars().all(|ch| ch.is_ascii_digit()) {
            return None;
        }
        Some(right.to_owned())
    }

    if let Some(found) = parse_one(raw) {
        return Some(found);
    }

    for line in raw.lines() {
        if let Some(found) = parse_one(line) {
            return Some(found);
        }
    }

    None
}

fn require_certificate<T>(result: Result<Option<T>, String>) -> Result<T, String> {
    result?.ok_or_else(|| "A verified certificate session is required".to_owned())
}

fn validate_api_url(url: &str) -> Result<reqwest::Url, String> {
    let parsed = reqwest::Url::parse(url).map_err(|_| "Invalid API URL".to_owned())?;
    if parsed.scheme() != "https"
        || parsed.host_str().is_none()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.fragment().is_some()
    {
        return Err("API URL must use HTTPS without credentials or fragments".to_owned());
    }
    Ok(parsed)
}

fn secure_api_client(url: &str, timeout: Duration) -> Result<Client, String> {
    validate_api_url(url)?;
    Client::builder()
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .timeout(timeout)
        .build()
        .map_err(|err| format!("http client build failed: {err}"))
}

fn verify_cert_number(cert_code: &str, api_hint: &str) -> Result<CertVerification, String> {
    if cert_code.trim().is_empty() {
        return Err("certno is empty".to_owned());
    }

    let peer_id = Config::get_id();
    if peer_id.trim().is_empty() {
        return Err("local peer id is empty".to_owned());
    }

    let verify_url = build_cert_verify_url(api_hint);
    let started_at = Instant::now();
    diagnostic_event(
        "cert.verify.request",
        &format!("url={verify_url} local_peer_id={peer_id}"),
    );
    let body = json!({
        "cert_code": cert_code.trim(),
        "peer_id": peer_id,
    });

    let client = secure_api_client(&verify_url, Duration::from_secs(10))?;

    let response = client
        .post(&verify_url)
        .json(&body)
        .send()
        .map_err(|err| format!("{verify_url}: request failed: {err}"))?;

    let status = response.status();
    let text = response
        .text()
        .map_err(|err| format!("{verify_url}: response body read failed: {err}"))?;
    diagnostic_event(
        "cert.verify.response",
        &format!(
            "status={} elapsed_ms={} body_bytes={}",
            status.as_u16(),
            started_at.elapsed().as_millis(),
            text.len()
        ),
    );

    if !status.is_success() {
        return Err(format!("{verify_url}: unexpected status {status}"));
    }

    let parsed: CertVerifyResponse =
        serde_json::from_str(&text).map_err(|err| format!("{verify_url}: invalid json: {err}"))?;

    if !parsed.success {
        let message = parsed.message.trim();
        return Err(format!(
            "{verify_url}: cert verify failed{}",
            if message.is_empty() {
                "".to_owned()
            } else {
                format!(" ({message})")
            }
        ));
    }

    let customer_id = parsed.customer_id.trim();
    if customer_id.is_empty() {
        return Err(format!(
            "{verify_url}: success=true but customer_id is missing"
        ));
    }

    let returned_peer_id = if parsed.mdesk_id.trim().is_empty() {
        parsed.peer_id.trim()
    } else {
        parsed.mdesk_id.trim()
    };
    if returned_peer_id.is_empty() {
        return Err(format!(
            "{verify_url}: success=true but verified peer id is missing"
        ));
    }
    if returned_peer_id != peer_id {
        return Err(format!(
            "{verify_url}: verified peer id mismatch (local={peer_id}, returned={returned_peer_id})"
        ));
    }

    let owner_mdesk_id = parsed.owner_mdesk_id.trim();
    if owner_mdesk_id.is_empty()
        || parsed.session_id <= 0
        || parsed.connection_token.trim().is_empty()
    {
        return Err(format!(
            "{verify_url}: success=true but the cert session binding is incomplete"
        ));
    }

    Ok(CertVerification {
        verify_url,
        peer_id,
        customer_id: customer_id.to_owned(),
        verified_peer_id: returned_peer_id.to_owned(),
        owner_mdesk_id: owner_mdesk_id.to_owned(),
        session_id: parsed.session_id,
        connection_token: parsed.connection_token.trim().to_owned(),
    })
}

fn build_cert_verify_url(api_hint: &str) -> String {
    let trimmed = api_hint.trim().trim_end_matches('/');
    if trimmed.is_empty() {
        return DEFAULT_CERT_VERIFY_URL.to_owned();
    }

    let lower = trimmed.to_ascii_lowercase();
    if lower.ends_with("/api/certno/verify") {
        trimmed.to_owned()
    } else if lower.ends_with("/api") {
        format!("{trimmed}/certno/verify")
    } else {
        format!("{trimmed}/api/certno/verify")
    }
}

#[derive(Debug)]
enum ReadinessPostResult {
    Success(String),
    LegacyEndpointUnavailable,
}

fn report_readiness_stage_async(
    verification: CertVerification,
    api_hint: String,
    stage: &'static str,
) {
    diagnostic_event(
        "readiness.progress_spawn",
        &format!("stage={stage} peer_id={}", verification.verified_peer_id),
    );
    thread::spawn(move || {
        if let Err(err) = report_readiness_stage(&verification, &api_hint, stage) {
            eprintln!("readiness progress failed: stage={stage} error={err}");
            diagnostic_event(
                "readiness.progress_failed",
                &format!("stage={stage} error={err}"),
            );
        }
    });
}

fn report_readiness_stage(
    verification: &CertVerification,
    api_hint: &str,
    stage: &str,
) -> Result<(), String> {
    match post_cert_readiness(verification, api_hint, "progress", Some(stage), 2)? {
        ReadinessPostResult::Success(url) => {
            println!("readiness progress success: stage={stage} url={url}");
            diagnostic_event(
                "readiness.progress_success",
                &format!("stage={stage} url={url}"),
            );
        }
        ReadinessPostResult::LegacyEndpointUnavailable => {
            println!("readiness progress endpoint unavailable: stage={stage}");
            diagnostic_event("readiness.progress_legacy", &format!("stage={stage}"));
        }
    }
    Ok(())
}

fn spawn_rendezvous_ready_reporter(verification: CertVerification, api_hint: String) {
    thread::spawn(move || {
        diagnostic_event(
            "rendezvous.wait.begin",
            &format!("peer_id={}", verification.verified_peer_id),
        );
        let started_at = Instant::now();
        let mut next_wait_log = Duration::from_secs(5);
        while !is_rendezvous_registered() {
            if started_at.elapsed() >= next_wait_log {
                println!(
                    "waiting for rendezvous registration before ready signal: elapsed={}s",
                    started_at.elapsed().as_secs()
                );
                diagnostic_event(
                    "rendezvous.wait.pending",
                    &format!("elapsed_ms={}", started_at.elapsed().as_millis()),
                );
                next_wait_log += Duration::from_secs(10);
            }
            thread::sleep(RENDEZVOUS_READY_POLL_INTERVAL);
        }

        println!(
            "rendezvous registration confirmed; reporting remote ready: peer_id={}",
            verification.verified_peer_id
        );
        diagnostic_event(
            "rendezvous.registered",
            &format!(
                "peer_id={} elapsed_ms={}",
                verification.verified_peer_id,
                started_at.elapsed().as_millis()
            ),
        );
        if let Err(err) = report_remote_ready(&verification, &api_hint) {
            eprintln!("remote ready report failed: {err}");
            diagnostic_event("readiness.ready_failed", &err);
        }
    });
}

fn report_remote_ready(verification: &CertVerification, api_hint: &str) -> Result<(), String> {
    match post_cert_readiness(verification, api_hint, "ready", None, 5)? {
        ReadinessPostResult::Success(url) => {
            println!("remote ready success: url={url}");
            diagnostic_event("readiness.ready_success", &format!("url={url}"));
            Ok(())
        }
        ReadinessPostResult::LegacyEndpointUnavailable => {
            println!("ready endpoint unavailable; using legacy agentnumupdate fallback");
            diagnostic_event(
                "readiness.ready_legacy",
                "ready endpoint unavailable; starting legacy fallback",
            );
            let agent_url = call_agentnumupdate(verification, api_hint)?;
            println!("legacy agentnumupdate success after ready: url={agent_url}");
            diagnostic_event("readiness.legacy_success", &format!("url={agent_url}"));
            Ok(())
        }
    }
}

fn post_cert_readiness(
    verification: &CertVerification,
    api_hint: &str,
    endpoint: &str,
    stage: Option<&str>,
    attempts: usize,
) -> Result<ReadinessPostResult, String> {
    let url = build_cert_readiness_url(api_hint, endpoint);
    let client = secure_api_client(&url, READINESS_HTTP_TIMEOUT)?;
    let body = if let Some(stage) = stage {
        json!({
            "session_id": verification.session_id,
            "owner_mdesk_id": verification.owner_mdesk_id,
            "peer_id": verification.verified_peer_id,
            "connection_token": verification.connection_token,
            "stage": stage,
        })
    } else {
        json!({
            "session_id": verification.session_id,
            "owner_mdesk_id": verification.owner_mdesk_id,
            "peer_id": verification.verified_peer_id,
            "connection_token": verification.connection_token,
        })
    };

    let max_attempts = attempts.max(1);
    let mut last_error = String::new();
    for attempt in 1..=max_attempts {
        let attempt_started = Instant::now();
        diagnostic_event(
            "readiness.http_request",
            &format!(
                "endpoint={endpoint} stage={} attempt={attempt}/{max_attempts} url={url}",
                stage.unwrap_or("ready")
            ),
        );
        match client.post(&url).json(&body).send() {
            Ok(response) => {
                let status = response.status();
                let response_body = response.text().unwrap_or_default();
                diagnostic_event(
                    "readiness.http_response",
                    &format!(
                        "endpoint={endpoint} stage={} attempt={attempt}/{max_attempts} status={} elapsed_ms={} body_bytes={}",
                        stage.unwrap_or("ready"),
                        status.as_u16(),
                        attempt_started.elapsed().as_millis(),
                        response_body.len()
                    ),
                );
                if status.is_success() {
                    return Ok(ReadinessPostResult::Success(url));
                }
                if status.as_u16() == 404 || status.as_u16() == 405 {
                    return Ok(ReadinessPostResult::LegacyEndpointUnavailable);
                }
                last_error = format!(
                    "{url}: unexpected status {status} on attempt {attempt} body_bytes={}",
                    response_body.len()
                );
                if status.is_client_error() {
                    break;
                }
            }
            Err(err) => {
                last_error = format!("{url}: request failed on attempt {attempt}: {err}");
                diagnostic_event(
                    "readiness.http_error",
                    &format!(
                        "endpoint={endpoint} stage={} attempt={attempt}/{max_attempts} elapsed_ms={} error={err}",
                        stage.unwrap_or("ready"),
                        attempt_started.elapsed().as_millis()
                    ),
                );
            }
        }

        if attempt < max_attempts {
            let shift = (attempt - 1).min(3) as u32;
            thread::sleep(Duration::from_millis(250_u64 << shift));
        }
    }
    Err(last_error)
}

fn build_cert_readiness_url(api_hint: &str, endpoint: &str) -> String {
    let verify_url = build_cert_verify_url(api_hint);
    let cert_api_base = verify_url
        .strip_suffix("/verify")
        .unwrap_or(verify_url.as_str())
        .trim_end_matches('/');
    format!("{cert_api_base}/{}", endpoint.trim_matches('/'))
}

fn call_agentnumupdate(verification: &CertVerification, api_hint: &str) -> Result<String, String> {
    let agent_url = build_agentnumupdate_url(
        api_hint,
        &verification.customer_id,
        &verification.verified_peer_id,
    );

    let client = secure_api_client(&agent_url, Duration::from_secs(10))?;

    let mut last_error = String::new();
    let body = json!({
        "session_id": verification.session_id,
        "owner_mdesk_id": verification.owner_mdesk_id,
        "connection_token": verification.connection_token,
    });
    for attempt in 1..=3 {
        let attempt_started = Instant::now();
        diagnostic_event(
            "readiness.legacy_request",
            &format!("attempt={attempt}/3 url={agent_url}"),
        );
        let response = match client.post(&agent_url).json(&body).send() {
            Ok(response) => response,
            Err(err) => {
                last_error = format!("{agent_url}: request failed on attempt {attempt}: {err}");
                diagnostic_event(
                    "readiness.legacy_error",
                    &format!(
                        "attempt={attempt}/3 elapsed_ms={} error={err}",
                        attempt_started.elapsed().as_millis()
                    ),
                );
                thread::sleep(Duration::from_millis(500));
                continue;
            }
        };

        let status = response.status();
        let response_body = response.text().unwrap_or_default();
        diagnostic_event(
            "readiness.legacy_response",
            &format!(
                "attempt={attempt}/3 status={} elapsed_ms={} body_bytes={}",
                status.as_u16(),
                attempt_started.elapsed().as_millis(),
                response_body.len()
            ),
        );
        if status.is_success() {
            return Ok(agent_url);
        }

        last_error = format!(
            "{agent_url}: unexpected status {} on attempt {} body_bytes={}",
            status,
            attempt,
            response_body.len()
        );
        thread::sleep(Duration::from_millis(500));
    }

    Err(last_error)
}

fn build_agentnumupdate_url(api_hint: &str, customer_id: &str, mdesk_id: &str) -> String {
    let mut base = if api_hint.trim().is_empty() {
        DEFAULT_AGENTNUMUPDATE_BASE_URL.to_owned()
    } else {
        let trimmed = api_hint.trim().trim_end_matches('/').to_owned();
        let lower = trimmed.to_ascii_lowercase();
        if lower.ends_with("/api/certno/verify") {
            trimmed[..trimmed.len() - "/api/certno/verify".len()].to_owned()
        } else if lower.ends_with("/api") {
            trimmed[..trimmed.len() - "/api".len()].to_owned()
        } else if lower.ends_with("/api/custom_app_config") {
            trimmed[..trimmed.len() - "/api/custom_app_config".len()].to_owned()
        } else {
            trimmed
        }
    };

    // Keep parity with Flutter flow that updates 787.kr while cert verify usually hits admin.787.kr.
    if base.contains("://admin.") {
        base = base.replacen("://admin.", "://", 1);
    }

    format!("{base}/api/agentnumupdate/{customer_id}/{mdesk_id}?agentid=0")
}

fn ensure_host_accepting_mode() {
    let stop_service = Config::get_option("stop-service");
    if !stop_service.is_empty() {
        println!(
            "host option override: stop-service '{}' -> ''",
            stop_service
        );
        Config::set_option("stop-service".to_owned(), "".to_owned());
    }
}

#[cfg(target_os = "windows")]
fn ensure_portable_service_ready() -> Result<(), String> {
    if platform::is_installed() {
        diagnostic_event("portable_service.skip", "MDesk is installed");
        return Ok(());
    }

    if portable_service::client::running() {
        diagnostic_event(
            "portable_service.already_running",
            "service responded immediately",
        );
        return Ok(());
    }

    diagnostic_event(
        "portable_service.start",
        "requesting quick-support SYSTEM service",
    );
    portable_service::client::start_quick_support_portable_service()
        .map_err(|err| err.to_string())?;
    let started_at = Instant::now();
    while started_at.elapsed() < PORTABLE_SERVICE_READY_TIMEOUT {
        if portable_service::client::running() {
            diagnostic_event(
                "portable_service.detected",
                &format!("elapsed_ms={}", started_at.elapsed().as_millis()),
            );
            return Ok(());
        }
        thread::sleep(Duration::from_millis(100));
    }

    Err(format!(
        "timed out after {} seconds",
        PORTABLE_SERVICE_READY_TIMEOUT.as_secs()
    ))
}

#[cfg(target_os = "windows")]
struct TrayIcon {
    hwnd: HWND,
    ui_thread: Option<thread::JoinHandle<()>>,
}

#[cfg(target_os = "windows")]
impl TrayIcon {
    fn spawn() -> Option<Self> {
        let (tx, rx) = std::sync::mpsc::channel::<Option<usize>>();
        let ui_thread = thread::spawn(move || {
            let class_name = to_wide("MDeskMiniTrayClass");
            let title = to_wide("MDeskMini Tray");
            let wnd_class = WNDCLASSW {
                lpfnWndProc: Some(tray_window_proc),
                lpszClassName: PCWSTR(class_name.as_ptr()),
                ..Default::default()
            };

            unsafe {
                let _ = RegisterClassW(&wnd_class);
            }

            let hwnd = match unsafe {
                CreateWindowExW(
                    WINDOW_EX_STYLE::default(),
                    PCWSTR(class_name.as_ptr()),
                    PCWSTR(title.as_ptr()),
                    WINDOW_STYLE::default(),
                    0,
                    0,
                    0,
                    0,
                    None,
                    None,
                    None,
                    None,
                )
            } {
                Ok(hwnd) => hwnd,
                Err(_) => {
                    let _ = tx.send(None);
                    return;
                }
            };

            if !add_tray_icon(hwnd) {
                let _ = tx.send(None);
                return;
            }

            let _ = tx.send(Some(hwnd.0 as usize));

            let mut msg = MSG::default();
            loop {
                let has_message = unsafe { GetMessageW(&mut msg, None, 0, 0) };
                if has_message.0 == 0 {
                    break;
                }
                unsafe {
                    let _ = TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
            }
        });

        match rx.recv_timeout(Duration::from_secs(2)) {
            Ok(Some(hwnd)) => Some(Self {
                hwnd: HWND(hwnd as *mut c_void),
                ui_thread: Some(ui_thread),
            }),
            _ => {
                let _ = ui_thread.join();
                None
            }
        }
    }

    fn close(mut self) {
        unsafe {
            let _ = PostMessageW(Some(self.hwnd), WM_CLOSE, WPARAM(0), LPARAM(0));
        }
        if let Some(handle) = self.ui_thread.take() {
            let _ = handle.join();
        }
    }
}

#[cfg(target_os = "windows")]
fn add_tray_icon(hwnd: HWND) -> bool {
    let icon = match load_application_icon() {
        Ok(icon) => icon,
        Err(_) => return false,
    };

    let mut data = NOTIFYICONDATAW::default();
    data.cbSize = std::mem::size_of::<NOTIFYICONDATAW>() as u32;
    data.hWnd = hwnd;
    data.uID = TRAY_ICON_ID;
    data.uFlags = NIF_ICON | NIF_TIP;
    data.hIcon = icon;
    // NOTIFYICONDATAW is packed on 32-bit Windows, so do not borrow szTip in place.
    let mut tip = data.szTip;
    copy_wide_truncated(&mut tip, "MDeskMini");
    data.szTip = tip;

    unsafe { Shell_NotifyIconW(NIM_ADD, &data).as_bool() }
}

#[cfg(target_os = "windows")]
fn load_application_icon() -> windows::core::Result<windows::Win32::UI::WindowsAndMessaging::HICON>
{
    let module = unsafe { GetModuleHandleW(None)? };
    let instance = HINSTANCE(module.0);
    unsafe {
        LoadIconW(Some(instance), PCWSTR(APP_ICON_RESOURCE_ID as *const u16))
            .or_else(|_| LoadIconW(None, IDI_APPLICATION))
    }
}

#[cfg(target_os = "windows")]
fn remove_tray_icon(hwnd: HWND) {
    let mut data = NOTIFYICONDATAW::default();
    data.cbSize = std::mem::size_of::<NOTIFYICONDATAW>() as u32;
    data.hWnd = hwnd;
    data.uID = TRAY_ICON_ID;

    unsafe {
        let _ = Shell_NotifyIconW(NIM_DELETE, &data);
    }
}

#[cfg(target_os = "windows")]
fn copy_wide_truncated(target: &mut [u16], value: &str) {
    if target.is_empty() {
        return;
    }
    let wide = to_wide(value);
    let len = target.len().min(wide.len());
    target[..len].copy_from_slice(&wide[..len]);
    target[target.len() - 1] = 0;
}

#[cfg(target_os = "windows")]
extern "system" fn tray_window_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_DESTROY => {
            remove_tray_icon(hwnd);
            unsafe {
                PostQuitMessage(0);
            }
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}

#[cfg(target_os = "windows")]
struct WaitingWindow {
    hwnd: HWND,
    label_hwnd: Option<HWND>,
    progress_fill_hwnd: Option<HWND>,
    ui_thread: Option<thread::JoinHandle<()>>,
}

#[cfg(target_os = "windows")]
impl WaitingWindow {
    fn spawn() -> Option<Self> {
        PROGRESS_TRACK_HWND.store(0, Ordering::Relaxed);
        PROGRESS_FILL_HWND.store(0, Ordering::Relaxed);

        let (tx, rx) = std::sync::mpsc::channel::<Option<(usize, usize, usize, usize)>>();
        let ui_thread = thread::spawn(move || {
            let class_name = to_wide("MDeskMiniWaitingClass");
            let title = to_wide("MDesk 원격대기중");
            let body = to_wide("원격 연결 요청을 기다리는 중입니다.");
            let static_cls = to_wide("STATIC");

            let wnd_class = WNDCLASSW {
                lpfnWndProc: Some(waiting_window_proc),
                hCursor: unsafe { LoadCursorW(None, IDC_ARROW).ok().unwrap_or_default() },
                hbrBackground: unsafe { GetSysColorBrush(COLOR_WINDOW) },
                lpszClassName: PCWSTR(class_name.as_ptr()),
                ..Default::default()
            };

            unsafe {
                let _ = RegisterClassW(&wnd_class);
            }

            let (window_x, window_y) =
                center_window_origin(WAITING_WINDOW_WIDTH, WAITING_WINDOW_HEIGHT);
            let hwnd = match unsafe {
                CreateWindowExW(
                    WINDOW_EX_STYLE::default(),
                    PCWSTR(class_name.as_ptr()),
                    PCWSTR(title.as_ptr()),
                    WINDOW_STYLE(
                        (WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_VISIBLE).0,
                    ),
                    window_x,
                    window_y,
                    WAITING_WINDOW_WIDTH,
                    WAITING_WINDOW_HEIGHT,
                    None,
                    None,
                    None,
                    None,
                )
            } {
                Ok(hwnd) => hwnd,
                Err(_) => {
                    let _ = tx.send(None);
                    return;
                }
            };

            let label_hwnd = unsafe {
                CreateWindowExW(
                    WINDOW_EX_STYLE::default(),
                    PCWSTR(static_cls.as_ptr()),
                    PCWSTR(body.as_ptr()),
                    WINDOW_STYLE((WS_CHILD | WS_VISIBLE).0 | STATIC_STYLE_CENTER),
                    20,
                    24,
                    320,
                    56,
                    Some(hwnd),
                    None,
                    None,
                    None,
                )
                .ok()
            };

            let empty_text = to_wide("");
            let progress_track_hwnd = unsafe {
                CreateWindowExW(
                    WINDOW_EX_STYLE::default(),
                    PCWSTR(static_cls.as_ptr()),
                    PCWSTR(empty_text.as_ptr()),
                    WINDOW_STYLE((WS_CHILD | WS_VISIBLE).0),
                    PROGRESS_X,
                    PROGRESS_Y,
                    PROGRESS_WIDTH,
                    PROGRESS_HEIGHT,
                    Some(hwnd),
                    None,
                    None,
                    None,
                )
                .ok()
            };

            let progress_fill_hwnd = unsafe {
                CreateWindowExW(
                    WINDOW_EX_STYLE::default(),
                    PCWSTR(static_cls.as_ptr()),
                    PCWSTR(empty_text.as_ptr()),
                    WINDOW_STYLE((WS_CHILD | WS_VISIBLE).0),
                    PROGRESS_X,
                    PROGRESS_Y,
                    1,
                    PROGRESS_HEIGHT,
                    Some(hwnd),
                    None,
                    None,
                    None,
                )
                .ok()
            };

            if let Some(label) = label_hwnd {
                let font = unsafe { GetStockObject(DEFAULT_GUI_FONT) };
                unsafe {
                    let _ = SendMessageW(
                        label,
                        WM_SETFONT,
                        Some(WPARAM(font.0 as usize)),
                        Some(LPARAM(1)),
                    );
                }
            }

            if let Some(track) = progress_track_hwnd {
                PROGRESS_TRACK_HWND.store(track.0 as isize, Ordering::Relaxed);
            }
            if let Some(fill) = progress_fill_hwnd {
                PROGRESS_FILL_HWND.store(fill.0 as isize, Ordering::Relaxed);
            }

            unsafe {
                let _ = ShowWindow(hwnd, SW_SHOW);
            }

            let label_ptr = label_hwnd.map(|h| h.0 as usize).unwrap_or(0);
            let track_ptr = progress_track_hwnd.map(|h| h.0 as usize).unwrap_or(0);
            let fill_ptr = progress_fill_hwnd.map(|h| h.0 as usize).unwrap_or(0);
            let _ = tx.send(Some((hwnd.0 as usize, label_ptr, track_ptr, fill_ptr)));

            let mut msg = MSG::default();
            loop {
                let has_message = unsafe { GetMessageW(&mut msg, None, 0, 0) };
                if has_message.0 == 0 {
                    break;
                }
                unsafe {
                    let _ = TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
            }
        });

        match rx.recv_timeout(Duration::from_secs(2)) {
            Ok(Some((hwnd, label_hwnd, _progress_track_hwnd, progress_fill_hwnd))) => Some(Self {
                hwnd: HWND(hwnd as *mut c_void),
                label_hwnd: if label_hwnd == 0 {
                    None
                } else {
                    Some(HWND(label_hwnd as *mut c_void))
                },
                progress_fill_hwnd: if progress_fill_hwnd == 0 {
                    None
                } else {
                    Some(HWND(progress_fill_hwnd as *mut c_void))
                },
                ui_thread: Some(ui_thread),
            }),
            _ => {
                let _ = ui_thread.join();
                None
            }
        }
    }

    fn set_status(&self, title: &str, body: &str) {
        if self.is_closed() {
            return;
        }
        let title_w = to_wide(title);
        let body_w = to_wide(body);
        unsafe {
            let _ = SetWindowTextW(self.hwnd, PCWSTR(title_w.as_ptr()));
            if let Some(label) = self.label_hwnd {
                let _ = SetWindowTextW(label, PCWSTR(body_w.as_ptr()));
            }
        }
    }

    fn set_progress(&self, title: &str, body: &str, percent: u8) {
        self.set_status(title, body);
        self.set_progress_value(percent);
    }

    fn set_progress_value(&self, percent: u8) {
        let Some(fill) = self.progress_fill_hwnd else {
            return;
        };
        if self.is_closed() {
            return;
        }

        let percent = i32::from(percent.min(100));
        let width = (PROGRESS_WIDTH * percent / 100).max(1);
        unsafe {
            let _ = MoveWindow(fill, PROGRESS_X, PROGRESS_Y, width, PROGRESS_HEIGHT, true);
        }
    }

    fn minimize(&self) {
        if self.is_closed() {
            return;
        }
        unsafe {
            let _ = ShowWindow(self.hwnd, SW_MINIMIZE);
        }
    }

    fn is_closed(&self) -> bool {
        unsafe { !IsWindow(Some(self.hwnd)).as_bool() }
    }

    fn close(mut self) {
        if !self.is_closed() {
            unsafe {
                let _ = PostMessageW(Some(self.hwnd), WM_CLOSE, WPARAM(0), LPARAM(0));
            }
        }
        if let Some(handle) = self.ui_thread.take() {
            let _ = handle.join();
        }
    }
}

#[cfg(target_os = "windows")]
fn center_window_origin(width: i32, height: i32) -> (i32, i32) {
    let screen_w = unsafe { GetSystemMetrics(SM_CXSCREEN) };
    let screen_h = unsafe { GetSystemMetrics(SM_CYSCREEN) };
    if screen_w <= 0 || screen_h <= 0 {
        return (100, 100);
    }
    let x = ((screen_w - width) / 2).max(0);
    let y = ((screen_h - height) / 2).max(0);
    (x, y)
}

#[cfg(target_os = "windows")]
fn progress_brush(slot: &AtomicIsize, color: COLORREF) -> isize {
    let existing = slot.load(Ordering::Relaxed);
    if existing != 0 {
        return existing;
    }

    let brush = unsafe { CreateSolidBrush(color) };
    let raw = brush.0 as isize;
    match slot.compare_exchange(0, raw, Ordering::Relaxed, Ordering::Relaxed) {
        Ok(_) => raw,
        Err(existing) => existing,
    }
}

#[cfg(target_os = "windows")]
extern "system" fn waiting_window_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_CTLCOLORSTATIC => {
            let hdc = HDC(wparam.0 as *mut c_void);
            let child_hwnd = lparam.0;
            if child_hwnd == PROGRESS_FILL_HWND.load(Ordering::Relaxed) {
                return LRESULT(progress_brush(&PROGRESS_FILL_BRUSH, COLORREF(0x0060AE27)));
            }
            if child_hwnd == PROGRESS_TRACK_HWND.load(Ordering::Relaxed) {
                return LRESULT(progress_brush(&PROGRESS_TRACK_BRUSH, COLORREF(0x00EBE7E5)));
            }
            unsafe {
                let _ = SetBkMode(hdc, TRANSPARENT);
                let _ = SetTextColor(hdc, COLORREF(GetSysColor(COLOR_WINDOWTEXT)));
                let brush = GetSysColorBrush(COLOR_WINDOW);
                LRESULT(brush.0 as isize)
            }
        }
        WM_DESTROY => {
            unsafe {
                PostQuitMessage(0);
            }
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}

fn monitor_pending_connections(
    server_thread: &thread::JoinHandle<()>,
    waiting_window: Option<&WaitingWindow>,
    approve_mode: ApproveModeArg,
    certificate_verified: bool,
) {
    #[cfg(not(target_os = "windows"))]
    {
        let _ = (server_thread, waiting_window, approve_mode, certificate_verified);
        println!("connection monitor is windows-only; running without popup UI");
        return;
    }

    #[cfg(target_os = "windows")]
    {
        println!("mini connection monitor active: {approve_mode:?}");
        diagnostic_event("connection.monitor.begin", "connection monitor loop active");
        let mut prompted: HashSet<i32> = HashSet::new();
        let mut had_remote_session = false;
        let mut idle_ticks_after_disconnect = 0u32;
        let mut last_status_title = String::new();
        let mut last_status_body = String::new();
        let mut connected_since: Option<Instant> = None;
        let mut minimized_after_connected = false;
        let mut last_client_state_summary = String::new();
        let mut empty_snapshot_reported = false;
        let mut previous_pending_ids: HashSet<i32> = HashSet::new();
        let mut previous_authorized_ids: HashSet<i32> = HashSet::new();

        while !server_thread.is_finished() {
            if let Some(window) = waiting_window {
                if window.is_closed() {
                    println!("waiting window closed by user; exiting mdeskmini");
                    diagnostic_event("ui.closed", "waiting window was closed by user");
                    platform::unregister_explorer_send_to_controller_menu();
                    common::global_clean();
                    secure_process_exit(0);
                }
            }

            let snapshot = flutter_ffi::cm_get_clients_state();
            if snapshot.trim().is_empty() {
                if !empty_snapshot_reported {
                    diagnostic_event(
                        "connection.snapshot_empty",
                        "waiting for connection manager state",
                    );
                    empty_snapshot_reported = true;
                }
                thread::sleep(Duration::from_millis(300));
                continue;
            }
            empty_snapshot_reported = false;

            let clients: Vec<CmClient> = match serde_json::from_str(&snapshot) {
                Ok(clients) => clients,
                Err(err) => {
                    diagnostic_event(
                        "connection.snapshot_invalid",
                        &format!("bytes={} error={err}", snapshot.len()),
                    );
                    thread::sleep(Duration::from_millis(300));
                    continue;
                }
            };

            let client_state_summary = clients
                .iter()
                .map(|client| {
                    format!(
                        "id={} authorized={} disconnected={} peer_id={} name={} ip={}",
                        client.id,
                        client.authorized,
                        client.disconnected,
                        client.peer_id,
                        client.name,
                        client.ip
                    )
                })
                .collect::<Vec<_>>()
                .join(" | ");
            if client_state_summary != last_client_state_summary {
                diagnostic_event(
                    "connection.state",
                    if client_state_summary.is_empty() {
                        "no clients"
                    } else {
                        &client_state_summary
                    },
                );
                last_client_state_summary = client_state_summary;
            }

            let pending_ids: HashSet<i32> = clients
                .iter()
                .filter(|client| !client.authorized && !client.disconnected)
                .map(|client| client.id)
                .collect();
            let authorized_ids: HashSet<i32> = clients
                .iter()
                .filter(|client| client.authorized && !client.disconnected)
                .map(|client| client.id)
                .collect();
            for client in clients.iter().filter(|client| {
                pending_ids.contains(&client.id) && !previous_pending_ids.contains(&client.id)
            }) {
                diagnostic_event(
                    "connection.request_received",
                    &format!(
                        "client_id={} peer_id={} name={} ip={}",
                        client.id, client.peer_id, client.name, client.ip
                    ),
                );
            }
            for client in clients.iter().filter(|client| {
                authorized_ids.contains(&client.id) && !previous_authorized_ids.contains(&client.id)
            }) {
                diagnostic_event(
                    "connection.authorized",
                    &format!(
                        "client_id={} peer_id={} name={} ip={}",
                        client.id, client.peer_id, client.name, client.ip
                    ),
                );
            }
            for client_id in previous_authorized_ids.difference(&authorized_ids) {
                diagnostic_event("connection.ended", &format!("client_id={client_id}"));
            }
            previous_pending_ids = pending_ids;
            previous_authorized_ids = authorized_ids;

            let active_remote_sessions = clients
                .iter()
                .filter(|client| client.authorized && !client.disconnected)
                .count();
            let has_pending_connection = clients
                .iter()
                .any(|client| !client.authorized && !client.disconnected);

            if active_remote_sessions > 0 {
                had_remote_session = true;
                idle_ticks_after_disconnect = 0;
            } else if has_pending_connection {
                idle_ticks_after_disconnect = 0;
            } else if had_remote_session {
                idle_ticks_after_disconnect += 1;
                if idle_ticks_after_disconnect >= REMOTE_EXIT_IDLE_TICKS {
                    println!("all remote sessions ended; exiting mdeskmini");
                    diagnostic_event(
                        "connection.all_ended",
                        &format!("idle_ticks={idle_ticks_after_disconnect}"),
                    );
                    platform::unregister_explorer_send_to_controller_menu();
                    common::global_clean();
                    secure_process_exit(0);
                }
            }

            if let Some(window) = waiting_window {
                let connected = clients
                    .iter()
                    .find(|client| client.authorized && !client.disconnected);
                let pending = clients
                    .iter()
                    .find(|client| !client.authorized && !client.disconnected);
                let connected_now = connected.is_some();

                let (status_title, status_body) = if let Some(client) = connected {
                    let peer = if client.name.trim().is_empty() {
                        if client.peer_id.trim().is_empty() {
                            "알 수 없는 사용자".to_owned()
                        } else {
                            client.peer_id.clone()
                        }
                    } else {
                        client.name.clone()
                    };
                    (
                        "MDesk 원격중".to_owned(),
                        format!("{peer} 님과 원격 연결이 유지되고 있습니다."),
                    )
                } else if pending.is_some() {
                    (
                        "MDesk 원격요청".to_owned(),
                        "원격 연결 요청이 도착했습니다. 승인 대기 중입니다.".to_owned(),
                    )
                } else {
                    (
                        "MDesk 원격대기중".to_owned(),
                        "원격 연결 요청을 기다리는 중입니다.".to_owned(),
                    )
                };

                if status_title != last_status_title || status_body != last_status_body {
                    window.set_status(&status_title, &status_body);
                    last_status_title = status_title;
                    last_status_body = status_body;
                }

                if connected_now {
                    if connected_since.is_none() {
                        connected_since = Some(Instant::now());
                        minimized_after_connected = false;
                    }
                    if !minimized_after_connected {
                        if let Some(since) = connected_since {
                            if since.elapsed() >= Duration::from_secs(5) {
                                window.minimize();
                                minimized_after_connected = true;
                            }
                        }
                    }
                } else {
                    connected_since = None;
                    minimized_after_connected = false;
                }
            }

            let active_ids: HashSet<i32> = clients.iter().map(|client| client.id).collect();
            prompted.retain(|id| active_ids.contains(id));

            for client in clients {
                let action = approval_action(
                    approve_mode,
                    certificate_verified,
                    client.authorized,
                    client.disconnected,
                );
                if action == ApprovalAction::None {
                    continue;
                }

                if !prompted.insert(client.id) {
                    continue;
                }

                had_remote_session = true;

                diagnostic_event(
                    if action == ApprovalAction::AutoAccept {
                        "connection.auto_approve"
                    } else {
                        "connection.manual_approval"
                    },
                    &format!(
                        "client_id={} peer_id={} name={} ip={}",
                        client.id, client.peer_id, client.name, client.ip
                    ),
                );

                let accepted = match action {
                    ApprovalAction::AutoAccept => true,
                    ApprovalAction::Prompt => prompt_approval(&client),
                    ApprovalAction::None => continue,
                };
                flutter_ffi::cm_login_res(client.id, accepted);
            }

            thread::sleep(Duration::from_millis(300));
        }

        platform::unregister_explorer_send_to_controller_menu();
        diagnostic_event(
            "connection.monitor.exit",
            "server thread finished; monitor loop exited",
        );
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ApprovalAction {
    None,
    AutoAccept,
    Prompt,
}

fn approval_action(
    mode: ApproveModeArg,
    certificate_verified: bool,
    authorized: bool,
    disconnected: bool,
) -> ApprovalAction {
    if !certificate_verified || authorized || disconnected {
        return ApprovalAction::None;
    }
    match mode {
        ApproveModeArg::Auto => ApprovalAction::AutoAccept,
        ApproveModeArg::Click | ApproveModeArg::Both => ApprovalAction::Prompt,
        ApproveModeArg::Password => ApprovalAction::None,
    }
}

#[cfg(target_os = "windows")]
fn prompt_approval(client: &CmClient) -> bool {
    let title = "MDeskMini";
    let body = format!(
        "원격을 허용할까요?\n\n원격 ID: {}\n이름: {}",
        if client.peer_id.is_empty() {
            "-"
        } else {
            client.peer_id.as_str()
        },
        if client.name.is_empty() {
            "-"
        } else {
            client.name.as_str()
        }
    );

    let title_w = to_wide(title);
    let body_w = to_wide(&body);
    let result = unsafe {
        MessageBoxW(
            None,
            PCWSTR(body_w.as_ptr()),
            PCWSTR(title_w.as_ptr()),
            MB_YESNO | MB_DEFBUTTON2 | MB_ICONQUESTION | MB_TOPMOST | MB_SETFOREGROUND,
        )
    };

    result == IDYES
}

#[cfg(target_os = "windows")]
#[allow(dead_code)]
fn show_error_popup(title: &str, body: &str) {
    let title_w = to_wide(title);
    let body_w = to_wide(body);
    unsafe {
        MessageBoxW(
            None,
            PCWSTR(body_w.as_ptr()),
            PCWSTR(title_w.as_ptr()),
            MB_OK | MB_ICONERROR | MB_TOPMOST | MB_SETFOREGROUND,
        );
    }
}

#[cfg(target_os = "windows")]
fn show_information_popup(title: &str, body: &str) {
    let title_w = to_wide(title);
    let body_w = to_wide(body);
    unsafe {
        MessageBoxW(
            None,
            PCWSTR(body_w.as_ptr()),
            PCWSTR(title_w.as_ptr()),
            MB_OK | MB_ICONINFORMATION | MB_TOPMOST | MB_SETFOREGROUND,
        );
    }
}

#[cfg(target_os = "windows")]
fn to_wide(value: &str) -> Vec<u16> {
    std::ffi::OsStr::new(value)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}

#[cfg(test)]
mod tests {
    #[test]
    fn certificate_bootstrap_fails_closed() {
        assert!(super::require_certificate::<()>(Ok(None)).is_err());
        assert!(super::require_certificate::<()>(Err("offline".into())).is_err());
        assert_eq!(super::require_certificate(Ok(Some(42))).unwrap(), 42);
    }

    #[test]
    fn default_cli_and_serve_policy_use_auto_approval() {
        assert_eq!(ServeOptions::default().approve_mode, ApproveModeArg::Auto);
        assert!(Cli::try_parse_from(["mdeskmini"]).unwrap().command.is_none());
        match Cli::try_parse_from(["mdeskmini", "serve"]).unwrap().command {
            Some(Commands::Serve { approve_mode, .. }) => {
                assert_eq!(approve_mode, ApproveModeArg::Auto);
                assert_eq!(approve_mode.as_config_value(), "click");
            }
            _ => panic!("expected serve command"),
        }
    }

    #[test]
    fn explicit_approval_modes_are_preserved() {
        for (value, expected) in [
            ("auto", ApproveModeArg::Auto),
            ("password", ApproveModeArg::Password),
            ("click", ApproveModeArg::Click),
            ("both", ApproveModeArg::Both),
        ] {
            match Cli::try_parse_from(["mdeskmini", "serve", "--approve-mode", value])
                .unwrap().command
            {
                Some(Commands::Serve { approve_mode, .. }) => assert_eq!(approve_mode, expected),
                _ => panic!("expected serve command"),
            }
        }
    }

    #[test]
    fn approval_policy_requires_bootstrap_and_preserves_password_validation() {
        for mode in [
            ApproveModeArg::Auto,
            ApproveModeArg::Password,
            ApproveModeArg::Click,
            ApproveModeArg::Both,
        ] {
            for verified in [false, true] {
                for authorized in [false, true] {
                    for disconnected in [false, true] {
                        let expected = if !verified || authorized || disconnected {
                            ApprovalAction::None
                        } else {
                            match mode {
                                ApproveModeArg::Auto => ApprovalAction::AutoAccept,
                                ApproveModeArg::Password => ApprovalAction::None,
                                ApproveModeArg::Click | ApproveModeArg::Both => {
                                    ApprovalAction::Prompt
                                }
                            }
                        };
                        assert_eq!(
                            approval_action(mode, verified, authorized, disconnected),
                            expected
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn authentication_api_requires_https() {
        for url in ["http://admin.787.kr/api", "file:///config", "https://user:pass@admin.787.kr", "https://admin.787.kr/#fragment", "not a url"] {
            assert!(super::validate_api_url(url).is_err(), "{url}");
        }
        assert!(super::validate_api_url(super::DEFAULT_CERT_VERIFY_URL).is_ok());
        assert!(super::validate_api_url("https://support.example:8443/api").is_ok());
    }

    #[cfg(target_os = "windows")]
    #[test]
    #[ignore = "requires PowerShell 7 and MDESK_TLS_FIXTURE pointing to the local TLS test script"]
    fn authentication_client_rejects_untrusted_loopback_certificate() {
        use std::{io::{BufRead, BufReader}, os::windows::process::CommandExt, process::Stdio};
        struct ChildGuard(std::process::Child);
        impl Drop for ChildGuard {
            fn drop(&mut self) { let _ = self.0.kill(); let _ = self.0.wait(); }
        }
        let fixture = std::env::var("MDESK_TLS_FIXTURE").expect("local TLS fixture path");
        let mut child = ChildGuard(std::process::Command::new("pwsh")
            .args(["-NoProfile", "-NonInteractive", "-File", &fixture])
            .stdout(Stdio::piped()).stderr(Stdio::inherit()).creation_flags(0x08000000)
            .spawn().expect("PowerShell 7 fixture"));
        let mut line = String::new();
        BufReader::new(child.0.stdout.take().unwrap()).read_line(&mut line).unwrap();
        let port: u16 = line.trim().parse().expect("loopback port");
        let url = format!("https://127.0.0.1:{port}/");
        let error = super::secure_api_client(&url, Duration::from_secs(10)).unwrap()
            .get(&url).send().expect_err("untrusted certificate must not be accepted");
        assert!(!error.is_timeout(), "a timeout is not certificate verification");
        let detail = format!("{error:?}").to_ascii_lowercase();
        // native-tls skips the OS error in source(), but Debug retains its
        // locale-independent CERT_E_UNTRUSTEDROOT / SEC_E_UNTRUSTED_ROOT code.
        let untrusted_root = [0x800b0109_u32, 0x80090325].iter()
            .any(|code| detail.contains(&format!("code: {}", *code as i32)));
        assert!(untrusted_root || detail.contains("certificate") || detail.contains("unknownissuer")
            || detail.contains("80090325"), "not a certificate rejection: {detail}");
    }

    use super::*;

    #[test]
    fn readiness_urls_follow_the_certificate_api_host() {
        assert_eq!(
            build_cert_readiness_url("https://admin.787.kr/api/certno/verify", "progress"),
            "https://admin.787.kr/api/certno/progress"
        );
        assert_eq!(
            build_cert_readiness_url("https://admin.787.kr", "ready"),
            "https://admin.787.kr/api/certno/ready"
        );
    }

    #[test]
    fn legacy_agent_update_still_uses_the_public_api_host() {
        assert_eq!(
            build_agentnumupdate_url(
                "https://admin.787.kr/api/certno/verify",
                "imedix",
                "123456789"
            ),
            "https://787.kr/api/agentnumupdate/imedix/123456789?agentid=0"
        );
    }

    #[test]
    fn rolled_back_private_server_cleanup_is_exact_match_only() {
        assert!(is_rolled_back_private_server(
            ROLLED_BACK_PRIVATE_ID_SERVER,
            ROLLED_BACK_PRIVATE_ID_SERVER
        ));
        assert!(is_rolled_back_private_server(
            " 172.16.100.100:21117 ",
            ROLLED_BACK_PRIVATE_RELAY_SERVER
        ));
        assert!(!is_rolled_back_private_server(
            "mdesk.imedixerp.co.kr:21116",
            ROLLED_BACK_PRIVATE_ID_SERVER
        ));
        assert!(!is_rolled_back_private_server(
            "172.16.100.101:21116",
            ROLLED_BACK_PRIVATE_ID_SERVER
        ));
    }

    #[test]
    fn native_clipboard_text_stops_at_utf16_null() {
        let units = "certno:3276"
            .encode_utf16()
            .chain([0, b'X' as u16])
            .collect::<Vec<_>>();
        assert_eq!(
            decode_windows_clipboard_text(&units).unwrap(),
            "certno:3276"
        );
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn installed_mdesk_path_comparison_is_case_insensitive() {
        assert!(same_windows_path(
            std::path::Path::new(r"C:\Program Files\MDesk\MDesk.exe"),
            std::path::Path::new(r"c:\program files\mdesk\mdesk.EXE")
        ));
        assert!(!same_windows_path(
            std::path::Path::new(r"C:\Program Files\MDesk\MDesk.exe"),
            std::path::Path::new(r"C:\Users\owner\Downloads\MDeskMini.exe")
        ));
    }

    #[test]
    fn log_cleanup_only_matches_mdeskmini_owned_files() {
        assert!(is_mdeskmini_log_file_name("MDeskMini_diagnostic.log"));
        assert!(is_mdeskmini_log_file_name(
            "MDeskMini-Win7-x64-UPX_rCURRENT.log"
        ));
        assert!(is_mdeskmini_log_file_name(
            "mdeskmini_r2026-08-08_22-09-13.log.gz"
        ));
        assert!(!is_mdeskmini_log_file_name("customer_notes.log"));
        assert!(!is_mdeskmini_log_file_name("MDeskMini.exe"));
    }

    #[test]
    fn mdeskmini_firewall_bootstrap_is_inherited_only_after_first_attempt() {
        let previous_process_marker = std::env::var_os(common::MDESKMINI_PROCESS_MARKER_ENV);
        let previous_firewall_marker =
            std::env::var_os(common::MDESKMINI_FIREWALL_BOOTSTRAPPED_ENV);

        std::env::remove_var(common::MDESKMINI_PROCESS_MARKER_ENV);
        std::env::remove_var(common::MDESKMINI_FIREWALL_BOOTSTRAPPED_ENV);
        common::mark_mdeskmini_process_tree();
        assert!(common::should_run_startup_firewall_bootstrap());

        common::mark_startup_firewall_bootstrapped();
        assert!(!common::should_run_startup_firewall_bootstrap());

        match previous_process_marker {
            Some(value) => std::env::set_var(common::MDESKMINI_PROCESS_MARKER_ENV, value),
            None => std::env::remove_var(common::MDESKMINI_PROCESS_MARKER_ENV),
        }
        match previous_firewall_marker {
            Some(value) => std::env::set_var(common::MDESKMINI_FIREWALL_BOOTSTRAPPED_ENV, value),
            None => std::env::remove_var(common::MDESKMINI_FIREWALL_BOOTSTRAPPED_ENV),
        }
    }
}
