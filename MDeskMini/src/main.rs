#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

use clap::{Parser, Subcommand, ValueEnum};
use hbb_common::config::{self, Config};
#[cfg(target_os = "windows")]
use librustdesk::platform;
use librustdesk::{common, flutter_ffi, portable_service, start_server, VERSION};
use reqwest::blocking::Client;
use serde::Deserialize;
use serde_json::json;
use std::collections::HashSet;
use std::thread;
use std::time::{Duration, Instant};

#[cfg(target_os = "windows")]
use std::ffi::c_void;
#[cfg(target_os = "windows")]
use std::os::windows::ffi::OsStrExt;
#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;
#[cfg(target_os = "windows")]
use std::process::Command;
#[cfg(target_os = "windows")]
use std::sync::atomic::{AtomicIsize, Ordering};
#[cfg(target_os = "windows")]
use windows::core::PCWSTR;
#[cfg(target_os = "windows")]
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
#[cfg(target_os = "windows")]
use windows::Win32::Graphics::Gdi::{
    CreateSolidBrush, GetStockObject, GetSysColor, GetSysColorBrush, SetBkMode, SetTextColor,
    COLOR_WINDOW, COLOR_WINDOWTEXT, DEFAULT_GUI_FONT, HDC, TRANSPARENT,
};
#[cfg(target_os = "windows")]
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
#[cfg(target_os = "windows")]
use windows::Win32::UI::HiDpi::{
    SetProcessDpiAwareness, SetProcessDpiAwarenessContext,
    DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, PROCESS_PER_MONITOR_DPI_AWARE,
};
#[cfg(target_os = "windows")]
use windows::Win32::UI::Shell::{
    Shell_NotifyIconW, NIF_ICON, NIF_TIP, NIM_ADD, NIM_DELETE, NOTIFYICONDATAW,
};
#[cfg(target_os = "windows")]
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DispatchMessageW, GetMessageW, GetSystemMetrics, IsWindow,
    LoadCursorW, LoadIconW, MessageBoxW, MoveWindow, PostMessageW, PostQuitMessage, RegisterClassW,
    SendMessageW, SetWindowTextW, ShowWindow, TranslateMessage, IDC_ARROW, IDI_APPLICATION, IDYES,
    MB_ICONERROR, MB_ICONQUESTION, MB_OK, MB_SETFOREGROUND, MB_TOPMOST, MB_YESNO, MSG, SM_CXSCREEN,
    SM_CYSCREEN, SW_MINIMIZE, SW_SHOW, WINDOW_EX_STYLE, WINDOW_STYLE, WM_CLOSE, WM_CTLCOLORSTATIC,
    WM_DESTROY, WM_SETFONT, WNDCLASSW, WS_CAPTION, WS_CHILD, WS_MINIMIZEBOX, WS_OVERLAPPED,
    WS_SYSMENU, WS_VISIBLE,
};
const DEFAULT_CERT_VERIFY_URL: &str = "https://admin.787.kr/api/certno/verify";
const DEFAULT_AGENTNUMUPDATE_BASE_URL: &str = "https://787.kr";
const DEFAULT_API_HINT: &str = "https://admin.787.kr";
#[cfg(target_os = "windows")]
const CREATE_NO_WINDOW_FLAG: u32 = 0x0800_0000;
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

#[derive(Parser)]
#[command(name = "mdeskmini", about = "Minimal host runtime with accept popup")]
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
        /// Host approve mode
        #[arg(long, value_enum, default_value_t = ApproveModeArg::Click)]
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
            approve_mode: ApproveModeArg::Click,
            password: None,
            api: Some(DEFAULT_API_HINT.to_owned()),
        }
    }
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum ApproveModeArg {
    Password,
    Click,
    Both,
}

impl ApproveModeArg {
    fn as_config_value(self) -> &'static str {
        match self {
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
    cert_code: String,
    verify_url: String,
    peer_id: String,
    customer_id: String,
    verified_peer_id: String,
    owner_mdesk_id: String,
    session_id: i64,
    connection_token: String,
}

fn main() {
    #[cfg(target_os = "windows")]
    enable_per_monitor_dpi_awareness();

    let first_arg = std::env::args().nth(1);

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

    let cli = Cli::parse();

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
fn enable_per_monitor_dpi_awareness() {
    // Keep whiteboard/process coordinates in physical pixels to avoid DPI virtualization offsets.
    if unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) }.is_ok()
    {
        return;
    }
    let _ = unsafe { SetProcessDpiAwareness(PROCESS_PER_MONITOR_DPI_AWARE) };
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
        std::process::exit(1);
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
            std::process::exit(1);
        }

        let result = run_send_to_controller_windows(path, select_path);
        common::global_clean();

        if let Err(err) = result {
            eprintln!("failed to request file transfer from Explorer: {err}");
            if show_errors {
                show_error_popup("MDeskMini", &err);
            }
            std::process::exit(1);
        }
    }

    #[cfg(not(target_os = "windows"))]
    {
        let _ = (path, select_path, show_errors);
        eprintln!("send-to-controller is only supported on Windows.");
        std::process::exit(1);
    }
}

#[cfg(target_os = "windows")]
fn run_send_to_controller_windows(path: String, select_path: bool) -> Result<(), String> {
    platform::send_explorer_path_to_controller(path, select_path)
}

fn run_serve(options: ServeOptions) {
    #[cfg(target_os = "windows")]
    let mut waiting_window = if options.headless {
        None
    } else {
        WaitingWindow::spawn()
    };
    #[cfg(target_os = "windows")]
    update_startup_progress(
        waiting_window.as_ref(),
        5,
        "MDesk 준비중",
        "프로그램을 초기화하고 있습니다.",
    );

    if !init_runtime_for_serve() {
        #[cfg(target_os = "windows")]
        update_startup_progress(
            waiting_window.as_ref(),
            100,
            "MDesk 준비 실패",
            "초기화에 실패했습니다.",
        );
        std::process::exit(1);
    }
    #[cfg(target_os = "windows")]
    platform::unregister_explorer_send_to_controller_menu();

    #[cfg(target_os = "windows")]
    update_startup_progress(
        waiting_window.as_ref(),
        30,
        "MDesk 준비중",
        "원격 접속 정책을 적용하고 있습니다.",
    );
    apply_host_policy(&options);

    #[cfg(target_os = "windows")]
    update_startup_progress(
        waiting_window.as_ref(),
        45,
        "MDesk 준비중",
        "인증번호를 확인하고 있습니다.",
    );
    if let Err(err) = apply_clipboard_cert_bootstrap(&options) {
        // 인증 실패 메시지박스는 사용자에게 노출하지 않고 로그만 남긴다.
        // verify 자체는 Flutter UI / 후속 인스턴스에서 다시 시도되므로 그대로 진행한다.
        eprintln!("cert bootstrap failed (ignored): {err}");
    }

    #[cfg(target_os = "windows")]
    update_startup_progress(
        waiting_window.as_ref(),
        60,
        "MDesk 준비중",
        "원격 연결 허용 상태를 준비하고 있습니다.",
    );
    ensure_host_accepting_mode();

    #[cfg(target_os = "windows")]
    match ensure_portable_service_ready() {
        Ok(()) => println!("SYSTEM portable service is ready"),
        Err(err) => {
            eprintln!("failed to prepare SYSTEM portable service; continuing without it: {err}")
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
    update_startup_progress(
        waiting_window.as_ref(),
        92,
        "MDesk 준비중",
        "원격 서버를 시작하고 있습니다.",
    );
    let server_thread = thread::spawn(|| {
        start_server(true, false);
    });

    #[cfg(target_os = "windows")]
    update_startup_progress(
        waiting_window.as_ref(),
        100,
        "MDesk 원격대기중",
        "원격 연결 요청을 기다리는 중입니다.",
    );

    if !options.headless {
        monitor_pending_connections(&server_thread, waiting_window.as_ref());
    }

    let _ = server_thread.join();
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
}

#[cfg(target_os = "windows")]
fn update_startup_progress(
    waiting_window: Option<&WaitingWindow>,
    percent: u8,
    title: &str,
    body: &str,
) {
    if let Some(window) = waiting_window {
        window.set_progress(title, body, percent);
    }
}

fn init_runtime() -> bool {
    if common::global_init() {
        true
    } else {
        eprintln!("global initialization failed");
        false
    }
}

fn init_runtime_for_serve() -> bool {
    if !init_runtime() {
        return false;
    }

    common::load_custom_client();
    config::apply_product_default_settings();

    #[cfg(target_os = "windows")]
    if !platform::windows::bootstrap() {
        eprintln!("windows bootstrap failed");
        return false;
    }

    true
}

fn apply_host_policy(options: &ServeOptions) {
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

fn apply_clipboard_cert_bootstrap(options: &ServeOptions) -> Result<(), String> {
    let Some(certnum) = clipboard_certnum() else {
        return Ok(());
    };

    println!("clipboard certno detected: {certnum}");

    match verify_cert_number(&certnum, options.api.as_deref().unwrap_or_default()) {
        Ok(verification) => {
            clear_clipboard_cert_if_matches(&certnum);
            Config::set_option("custom-certno".to_owned(), "true".to_owned());
            Config::set_option("custom-agentid".to_owned(), "0".to_owned());
            Config::set_option("custom-id".to_owned(), verification.customer_id.clone());
            match call_agentnumupdate(&verification, options.api.as_deref().unwrap_or_default()) {
                Ok(agent_url) => {
                    println!("agentnumupdate success: url={agent_url}");
                }
                Err(err) => {
                    eprintln!("agentnumupdate failed: {err}");
                }
            }
            println!(
                "cert verify success: customer_id={} peer_id={} verified_peer_id={} cert_code={} url={}",
                verification.customer_id,
                verification.peer_id,
                verification.verified_peer_id,
                verification.cert_code,
                verification.verify_url
            );
            Ok(())
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
        let output = Command::new("powershell")
            .creation_flags(CREATE_NO_WINDOW_FLAG)
            .args([
                "-NoProfile",
                "-WindowStyle",
                "Hidden",
                "-Command",
                "Get-Clipboard -Raw",
            ])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let text = String::from_utf8_lossy(&output.stdout).trim().to_owned();
        if text.is_empty() {
            None
        } else {
            Some(text)
        }
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
            Ok(()) => println!("clipboard certno cleared"),
            Err(err) => eprintln!("failed to clear clipboard certno: {err}"),
        }
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = expected_certnum;
    }
}

#[cfg(target_os = "windows")]
fn clear_windows_clipboard() -> Result<(), String> {
    let status = Command::new("powershell")
        .creation_flags(CREATE_NO_WINDOW_FLAG)
        .args([
            "-NoProfile",
            "-WindowStyle",
            "Hidden",
            "-Command",
            "Set-Clipboard -Value ''",
        ])
        .status()
        .map_err(|err| format!("failed to run powershell Set-Clipboard: {err}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!(
            "powershell Set-Clipboard failed with status {status}"
        ))
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

fn verify_cert_number(cert_code: &str, api_hint: &str) -> Result<CertVerification, String> {
    if cert_code.trim().is_empty() {
        return Err("certno is empty".to_owned());
    }

    let peer_id = Config::get_id();
    if peer_id.trim().is_empty() {
        return Err("local peer id is empty".to_owned());
    }

    let verify_url = build_cert_verify_url(api_hint);
    let body = json!({
        "cert_code": cert_code.trim(),
        "peer_id": peer_id,
    });

    let client = Client::builder()
        .danger_accept_invalid_certs(true)
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|err| format!("http client build failed: {err}"))?;

    let response = client
        .post(&verify_url)
        .json(&body)
        .send()
        .map_err(|err| format!("{verify_url}: request failed: {err}"))?;

    let status = response.status();
    let text = response
        .text()
        .map_err(|err| format!("{verify_url}: response body read failed: {err}"))?;

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
    if owner_mdesk_id.is_empty() || parsed.session_id <= 0 || parsed.connection_token.trim().is_empty() {
        return Err(format!(
            "{verify_url}: success=true but the cert session binding is incomplete"
        ));
    }

    Ok(CertVerification {
        cert_code: cert_code.trim().to_owned(),
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

fn call_agentnumupdate(verification: &CertVerification, api_hint: &str) -> Result<String, String> {
    let agent_url = build_agentnumupdate_url(
        api_hint,
        &verification.customer_id,
        &verification.verified_peer_id,
    );

    let client = Client::builder()
        .danger_accept_invalid_certs(true)
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|err| format!("http client build failed: {err}"))?;

    let mut last_error = String::new();
    let body = json!({
        "session_id": verification.session_id,
        "owner_mdesk_id": verification.owner_mdesk_id,
        "connection_token": verification.connection_token,
    });
    for attempt in 1..=3 {
        let response = match client.post(&agent_url).json(&body).send() {
            Ok(response) => response,
            Err(err) => {
                last_error = format!("{agent_url}: request failed on attempt {attempt}: {err}");
                thread::sleep(Duration::from_millis(500));
                continue;
            }
        };

        let status = response.status();
        let body = response.text().unwrap_or_default();
        if status.is_success() {
            return Ok(agent_url);
        }

        last_error = format!(
            "{agent_url}: unexpected status {} on attempt {} body={}",
            status, attempt, body
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
        return Ok(());
    }

    if portable_service::client::running() {
        return Ok(());
    }

    portable_service::client::start_quick_support_portable_service()
        .map_err(|err| err.to_string())?;
    let started_at = Instant::now();
    while started_at.elapsed() < PORTABLE_SERVICE_READY_TIMEOUT {
        if portable_service::client::running() {
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
) {
    #[cfg(not(target_os = "windows"))]
    {
        let _ = (server_thread, waiting_window);
        println!("popup approval loop is windows-only; running without popup UI");
        return;
    }

    #[cfg(target_os = "windows")]
    {
        println!("mini approval popup loop active");
        let mut prompted: HashSet<i32> = HashSet::new();
        let mut had_remote_session = false;
        let mut idle_ticks_after_disconnect = 0u32;
        let mut last_status_title = String::new();
        let mut last_status_body = String::new();
        let mut connected_since: Option<Instant> = None;
        let mut minimized_after_connected = false;

        while !server_thread.is_finished() {
            if let Some(window) = waiting_window {
                if window.is_closed() {
                    println!("waiting window closed by user; exiting mdeskmini");
                    platform::unregister_explorer_send_to_controller_menu();
                    common::global_clean();
                    std::process::exit(0);
                }
            }

            let snapshot = flutter_ffi::cm_get_clients_state();
            if snapshot.trim().is_empty() {
                thread::sleep(Duration::from_millis(300));
                continue;
            }

            let clients: Vec<CmClient> = match serde_json::from_str(&snapshot) {
                Ok(clients) => clients,
                Err(_) => {
                    thread::sleep(Duration::from_millis(300));
                    continue;
                }
            };

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
                    platform::unregister_explorer_send_to_controller_menu();
                    common::global_clean();
                    std::process::exit(0);
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
                if client.authorized || client.disconnected {
                    continue;
                }

                if !prompted.insert(client.id) {
                    continue;
                }

                had_remote_session = true;

                flutter_ffi::cm_login_res(client.id, true);
            }

            thread::sleep(Duration::from_millis(300));
        }

        platform::unregister_explorer_send_to_controller_menu();
    }
}

#[cfg(target_os = "windows")]
#[allow(dead_code)]
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
            MB_YESNO | MB_ICONQUESTION | MB_TOPMOST | MB_SETFOREGROUND,
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
fn to_wide(value: &str) -> Vec<u16> {
    std::ffi::OsStr::new(value)
        .encode_wide()
        .chain(std::iter::once(0))
        .collect()
}
