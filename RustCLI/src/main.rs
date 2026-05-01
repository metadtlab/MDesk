#![cfg_attr(all(target_os = "windows", not(debug_assertions)), windows_subsystem = "windows")]

use clap::{Parser, Subcommand};
use hbb_common::base64::{
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
    Engine as _,
};
use hbb_common::config::{self, Config};
use librustdesk::{common, flutter, platform, start_server, VERSION};
use reqwest::blocking::Client;
use serde::Deserialize;
use serde_json::json;
use std::env;
use std::path::Path;
use std::time::Duration;
#[cfg(target_os = "windows")]
use std::process::Command;

const DEFAULT_CUSTOM_CONFIG_URL: &str = "https://787.kr/api/custom_app_config";
const DEFAULT_CERT_VERIFY_URL: &str = "https://admin.787.kr/api/certno/verify";
const DEFAULT_AGENTNUMUPDATE_BASE_URL: &str = "https://787.kr";
const ENV_MDESK_APPNAME: &str = "MDESK_APPNAME";
const ENV_RUSTDESK_APPNAME: &str = "RUSTDESK_APPNAME";

#[derive(Parser)]
#[command(name = "rustcli", version = VERSION, about = "Headless MDesk CLI")]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    /// Start the host server in the foreground
    Serve,
    /// Print the current device ID
    Id,
    /// Print the current version
    Version,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct PortableParams {
    source: String,
    host: String,
    key: String,
    api: String,
    relay: String,
    password: String,
    id: String,
    agentid: String,
    certno: String,
    certnum: String,
    ipdirect: String,
    portable_flag: bool,
}

impl PortableParams {
    fn is_portable(&self) -> bool {
        self.portable_flag
            || !self.host.is_empty()
            || !self.key.is_empty()
            || !self.api.is_empty()
            || !self.relay.is_empty()
            || !self.password.is_empty()
            || !self.id.is_empty()
            || !self.agentid.is_empty()
            || !self.certno.is_empty()
            || !self.certnum.is_empty()
            || !self.ipdirect.is_empty()
    }

    fn is_cert_mode(&self) -> bool {
        self.certno.eq_ignore_ascii_case("true") || !self.certnum.trim().is_empty()
    }

    fn effective_user_id(&self) -> Option<&str> {
        if !self.is_portable() {
            return None;
        }
        if self.is_cert_mode() {
            Some("cert")
        } else if !self.id.is_empty() {
            Some(self.id.as_str())
        } else {
            Some("admin")
        }
    }
}

#[derive(Debug, Deserialize)]
struct CustomConfigResponse {
    #[serde(default)]
    code: i32,
    #[serde(default)]
    data: Option<CustomConfigData>,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct CustomConfigData {
    #[serde(default)]
    app_name: String,
    #[serde(default)]
    logo_url: String,
    #[serde(default)]
    password: String,
    #[serde(default)]
    encrypted_password: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    description: String,
}

#[derive(Debug, Deserialize)]
struct CertVerifyResponse {
    #[serde(default)]
    success: bool,
    #[serde(default)]
    customer_id: String,
    #[serde(default)]
    mdesk_id: String,
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
}

#[derive(Debug)]
struct PortableBootstrap {
    params: PortableParams,
    resolved_user_id: Option<String>,
    cert_verification: Option<CertVerification>,
    cert_agentnumupdate_url: Option<String>,
    custom_config: Option<CustomConfigData>,
    effective_password: Option<EffectivePassword>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PasswordSource {
    PortableArgument,
    CustomConfig,
}

#[derive(Debug, Clone)]
struct EffectivePassword {
    value: String,
    source: PasswordSource,
}

fn main() {
    if let Some(mode) = internal_mode_from_arg(env::args().nth(1).as_deref()) {
        match mode {
            InternalMode::ConnectionManager => run_connection_manager(),
        }
        return;
    }

    let cli = Cli::parse();

    match cli.command {
        Some(Commands::Serve) => run_serve(),
        Some(Commands::Id) => run_id(),
        Some(Commands::Version) => println!("{VERSION}"),
        None => run_serve(),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum InternalMode {
    ConnectionManager,
}

fn internal_mode_from_arg(arg: Option<&str>) -> Option<InternalMode> {
    match arg {
        Some("--cm") | Some("--cm-no-ui") => Some(InternalMode::ConnectionManager),
        _ => None,
    }
}

fn init_runtime() -> bool {
    if common::global_init() {
        true
    } else {
        eprintln!("Global initialization failed.");
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
        eprintln!("Windows bootstrap failed.");
        return false;
    }

    true
}

fn run_id() {
    prepare_rustdesk_portable_env();

    if !init_runtime() {
        std::process::exit(1);
    }

    println!("{}", Config::get_id());
    common::global_clean();
}

fn run_serve() {
    let portable = match bootstrap_portable_mode() {
        Ok(portable) => portable,
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(1);
        }
    };

    if !init_runtime_for_serve() {
        std::process::exit(1);
    }

    if let Some(portable) = portable.as_ref() {
        apply_portable_runtime_settings(portable);
        print_portable_bootstrap(portable);
    }

    ensure_host_accepting_mode();

    common::test_rendezvous_server();
    common::test_nat_type();

    println!("starting rustcli host server");
    println!("version={VERSION}");
    println!("id={}", Config::get_id());

    start_server(true, false);
    common::global_clean();
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

fn run_connection_manager() {
    let portable = match bootstrap_portable_mode() {
        Ok(portable) => portable,
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(1);
        }
    };

    if !init_runtime_for_serve() {
        std::process::exit(1);
    }

    if let Some(portable) = portable.as_ref() {
        apply_portable_runtime_settings(portable);
    }

    println!("starting rustcli hidden connection manager");
    flutter::connection_manager::start_cm_no_ui();
    common::global_clean();
}

fn bootstrap_portable_mode() -> Result<Option<PortableBootstrap>, String> {
    prepare_rustdesk_portable_env();

    let Some(source) = portable_source_name() else {
        return Ok(None);
    };
    let mut params = parse_portable_params(&source);
    merge_clipboard_portable_params(&mut params);
    if !params.is_portable() {
        return Ok(None);
    }

    let cert_verification = if params.is_cert_mode() {
        let verification = verify_cert_number(&params)
            .map_err(|err| format!("portable cert verification failed: {err}"))?;
        clear_clipboard_cert_if_matches(&verification.cert_code);
        Some(verification)
    } else {
        None
    };

    let cert_agentnumupdate_url = cert_verification.as_ref().and_then(|verification| {
        match call_agentnumupdate_with_cert(verification, &params.api) {
            Ok(url) => Some(url),
            Err(err) => {
                eprintln!("portable agentnumupdate failed: {err}");
                None
            }
        }
    });

    let resolved_user_id = cert_verification
        .as_ref()
        .map(|verification| verification.customer_id.clone())
        .or_else(|| params.effective_user_id().map(str::to_owned));

    let custom_config = match resolved_user_id.as_deref() {
        Some(user_id) => match fetch_custom_config(user_id, &params.api) {
            Ok(config) => Some(config),
            Err(err) => {
                eprintln!("portable custom config lookup failed: {err}");
                None
            }
        },
        None => None,
    };

    let effective_password = resolve_effective_password(&params, custom_config.as_ref());

    Ok(Some(PortableBootstrap {
        params,
        resolved_user_id,
        cert_verification,
        cert_agentnumupdate_url,
        custom_config,
        effective_password,
    }))
}

fn merge_clipboard_portable_params(params: &mut PortableParams) {
    let Some(clipboard_source) = portable_source_from_clipboard() else {
        return;
    };
    let clipboard_params = parse_portable_params(&clipboard_source);
    if !clipboard_params.is_portable() {
        return;
    }

    if clipboard_params.is_cert_mode() {
        params.portable_flag = true;
        params.certno = if clipboard_params.certno.is_empty() {
            "true".to_owned()
        } else {
            clipboard_params.certno
        };
        if !clipboard_params.certnum.is_empty() {
            params.certnum = clipboard_params.certnum;
        }
        if params.api.is_empty() {
            params.api = clipboard_params.api;
        }
        params.source = if params.source.is_empty() {
            clipboard_source
        } else {
            format!("{} + clipboard:{}", params.source, clipboard_source)
        };
        return;
    }

    if !params.is_portable() {
        *params = clipboard_params;
    }
}

fn resolve_effective_password(
    params: &PortableParams,
    custom_config: Option<&CustomConfigData>,
) -> Option<EffectivePassword> {
    if !params.password.trim().is_empty() {
        return Some(EffectivePassword {
            value: params.password.trim().to_owned(),
            source: PasswordSource::PortableArgument,
        });
    }

    let password = custom_config
        .map(|config| config.password.trim())
        .unwrap_or_default();
    if password.is_empty() {
        None
    } else {
        Some(EffectivePassword {
            value: password.to_owned(),
            source: PasswordSource::CustomConfig,
        })
    }
}

fn apply_portable_runtime_settings(bootstrap: &PortableBootstrap) {
    let params = &bootstrap.params;

    Config::set_option("is-portable".to_owned(), "Y".to_owned());
    if params.is_cert_mode() {
        Config::set_option("custom-certno".to_owned(), "true".to_owned());
    } else {
        Config::set_option("custom-certno".to_owned(), "".to_owned());
    }
    if !params.host.is_empty() {
        Config::set_option("custom-rendezvous-server".to_owned(), params.host.clone());
    }
    if !params.key.is_empty() {
        Config::set_option("key".to_owned(), params.key.clone());
    }
    if !params.relay.is_empty() {
        Config::set_option("relay-server".to_owned(), params.relay.clone());
    }
    if !params.api.is_empty() {
        Config::set_option("api-server".to_owned(), params.api.clone());
    }
    if let Some(user_id) = bootstrap.resolved_user_id.as_ref() {
        if !user_id.is_empty() {
            Config::set_option("custom-id".to_owned(), user_id.clone());
        }
    } else if !params.id.is_empty() {
        Config::set_option("custom-id".to_owned(), params.id.clone());
    }

    if bootstrap.cert_verification.is_some() {
        Config::set_option("custom-agentid".to_owned(), "0".to_owned());
    } else if !params.agentid.is_empty() {
        Config::set_option("custom-agentid".to_owned(), params.agentid.clone());
    }

    if let Some(password) = bootstrap.effective_password.as_ref() {
        apply_login_password(password);
    }
}

fn apply_login_password(password: &EffectivePassword) {
    Config::set_permanent_password(&password.value);
    Config::set_option(
        "verification-method".to_owned(),
        "use-permanent-password".to_owned(),
    );
    Config::set_option("approve-mode".to_owned(), "password".to_owned());
}

fn prepare_rustdesk_portable_env() {
    let mdesk_appname = env::var(ENV_MDESK_APPNAME).ok();
    let rustdesk_appname = env::var(ENV_RUSTDESK_APPNAME).ok();

    if rustdesk_appname.as_deref().unwrap_or("").is_empty() {
        if let Some(value) = mdesk_appname {
            if !value.trim().is_empty() {
                env::set_var(ENV_RUSTDESK_APPNAME, value);
            }
        }
    }
}

fn portable_source_name() -> Option<String> {
    for key in [ENV_MDESK_APPNAME, ENV_RUSTDESK_APPNAME] {
        if let Ok(value) = env::var(key) {
            let value = value.trim();
            if !value.is_empty() {
                return Some(portable_file_name_only(value));
            }
        }
    }

    env::current_exe().ok().and_then(|path| {
        path.file_name()
            .map(|name| name.to_string_lossy().to_string())
    })
}

fn portable_source_from_clipboard() -> Option<String> {
    #[cfg(target_os = "windows")]
    {
        let output = Command::new("powershell")
            .args(["-NoProfile", "-Command", "Get-Clipboard -Raw"])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let clipboard = String::from_utf8_lossy(&output.stdout);
        extract_portable_source_candidate(&clipboard)
    }
    #[cfg(not(target_os = "windows"))]
    {
        None
    }
}

fn clear_clipboard_cert_if_matches(expected_certnum: &str) {
    #[cfg(target_os = "windows")]
    {
        let is_same_cert = portable_source_from_clipboard()
            .map(|source| parse_portable_params(&source))
            .map(|params| params.certnum.trim().eq(expected_certnum))
            .unwrap_or(false);
        if !is_same_cert {
            return;
        }
        match clear_windows_clipboard() {
            Ok(()) => println!("portable clipboard certno cleared"),
            Err(err) => eprintln!("portable clipboard certno clear failed: {err}"),
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
        .args(["-NoProfile", "-Command", "Set-Clipboard -Value ''"])
        .status()
        .map_err(|err| format!("failed to run powershell Set-Clipboard: {err}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("powershell Set-Clipboard failed with status {status}"))
    }
}

fn extract_portable_source_candidate(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }

    if let Some(certnum) = extract_certnum_from_clipboard_text(trimmed) {
        return Some(format!("portable-certno=true-certnum={certnum}"));
    }

    let mut candidates = Vec::new();
    candidates.push(trimmed.to_owned());

    for line in trimmed.lines() {
        let line = line.trim();
        if !line.is_empty() {
            candidates.push(line.to_owned());
        }
    }

    for token in trimmed.split_whitespace() {
        let token = token.trim_matches(|c: char| {
            c == '"' || c == '\'' || c == '`' || c == ';' || c == ',' || c == ')' || c == '('
        });
        if !token.is_empty() {
            candidates.push(token.to_owned());
        }
    }

    for quote in ['"', '\''] {
        for part in trimmed.split(quote) {
            let part = part.trim();
            if !part.is_empty() {
                candidates.push(part.to_owned());
            }
        }
    }

    candidates.sort_by_key(|s| s.len());
    candidates.dedup();

    for candidate in candidates {
        if parse_portable_params(&candidate).is_portable() {
            return Some(candidate);
        }
    }

    None
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

fn portable_file_name_only(raw: &str) -> String {
    let trimmed = raw.trim();
    let lower = trimmed.to_ascii_lowercase();
    if [
        "host=",
        "api=",
        "id=",
        "agentid=",
        "portable",
        "certno=",
        "certnum=",
        "ipdirect=",
    ]
    .iter()
    .any(|marker| lower.contains(marker))
    {
        return trimmed.to_owned();
    }

    let candidate = Path::new(trimmed)
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_else(|| trimmed.to_owned());
    candidate.trim().to_owned()
}

fn parse_portable_params(source: &str) -> PortableParams {
    let mut params = PortableParams {
        source: source.to_owned(),
        ..PortableParams::default()
    };

    let stripped = strip_known_exe_suffix(source);
    let lower = stripped.to_ascii_lowercase();
    let markers = [
        lower.find("host="),
        lower.find("p=["),
        lower.find("portable"),
        lower.find("id="),
        lower.find("agentid="),
        lower.find("api="),
        lower.find("certno="),
        lower.find("certnum="),
        lower.find("ipdirect="),
    ];

    let Some(start_pos) = markers.into_iter().flatten().min() else {
        return params;
    };

    let portable_segment = stripped[start_pos..].replace('-', ",");
    let tokens = portable_segment
        .split(',')
        .map(str::trim)
        .filter(|part| !part.is_empty());

    for token in tokens {
        let lower = token.to_ascii_lowercase();
        if lower == "portable" {
            params.portable_flag = true;
            continue;
        }
        if lower.starts_with("host=") {
            params.host = token[5..].trim().to_owned();
            continue;
        }
        if lower.starts_with("key=") {
            params.key = token[4..].trim().to_owned();
            continue;
        }
        if lower.starts_with("api=") {
            params.api = token[4..].trim().to_owned();
            continue;
        }
        if lower.starts_with("relay=") {
            params.relay = token[6..].trim().to_owned();
            continue;
        }
        if lower.starts_with("agentid=") {
            params.agentid = token[8..].trim().to_owned();
            continue;
        }
        if lower.starts_with("id=") {
            params.id = token[3..].trim().to_owned();
            continue;
        }
        if lower.starts_with("password=") {
            params.password = token[9..].trim().to_owned();
            continue;
        }
        if lower.starts_with("certno=") {
            params.certno = token[7..].trim().to_owned();
            continue;
        }
        if lower.starts_with("certnum=") {
            params.certnum = token[8..].trim().to_owned();
            continue;
        }
        if lower.starts_with("ipdirect=") {
            params.ipdirect = token[9..].trim().to_owned();
            continue;
        }
        if lower.starts_with("p=[") && lower.ends_with(']') && token.len() > 4 {
            params.password = decode_portable_password(token[3..token.len() - 1].trim());
            continue;
        }
        if lower.starts_with("p=") {
            params.password = token[2..].trim().to_owned();
        }
    }

    params
}

fn decode_portable_password(encoded: &str) -> String {
    let decoded = URL_SAFE_NO_PAD
        .decode(encoded)
        .or_else(|_| STANDARD.decode(encoded));

    if let Ok(bytes) = decoded {
        let key = b"rustdesk";
        let decrypted: Vec<u8> = bytes
            .iter()
            .enumerate()
            .map(|(index, value)| value ^ key[index % key.len()])
            .collect();
        String::from_utf8(decrypted).unwrap_or_else(|_| encoded.to_owned())
    } else {
        encoded.to_owned()
    }
}

fn strip_known_exe_suffix(source: &str) -> &str {
    let lower = source.to_ascii_lowercase();
    if lower.ends_with(".exe.exe") {
        &source[..source.len() - 8]
    } else if lower.ends_with(".exe") {
        &source[..source.len() - 4]
    } else {
        source
    }
}

fn fetch_custom_config(user_id: &str, api_hint: &str) -> Result<CustomConfigData, String> {
    let client = Client::builder()
        .danger_accept_invalid_certs(true)
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|err| format!("http client build failed: {err}"))?;

    let mut candidates = Vec::new();
    if !api_hint.trim().is_empty() {
        candidates.push(build_custom_config_url(api_hint));
    }
    if !candidates
        .iter()
        .any(|candidate| candidate == DEFAULT_CUSTOM_CONFIG_URL)
    {
        candidates.push(DEFAULT_CUSTOM_CONFIG_URL.to_owned());
    }

    let body = json!({ "username": user_id });
    let mut last_error = String::from("custom config request was not attempted");

    for url in candidates {
        let response = match client.post(&url).json(&body).send() {
            Ok(response) => response,
            Err(err) => {
                last_error = format!("{url}: request failed: {err}");
                continue;
            }
        };

        let status = response.status();
        let text = match response.text() {
            Ok(text) => text,
            Err(err) => {
                last_error = format!("{url}: response body read failed: {err}");
                continue;
            }
        };

        if !status.is_success() {
            last_error = format!("{url}: unexpected status {status}");
            continue;
        }

        let parsed: CustomConfigResponse = match serde_json::from_str(&text) {
            Ok(parsed) => parsed,
            Err(err) => {
                last_error = format!("{url}: invalid json response: {err}");
                continue;
            }
        };

        if parsed.code != 1 {
            last_error = format!("{url}: api returned code {}", parsed.code);
            continue;
        }

        if let Some(data) = parsed.data {
            return Ok(data);
        }

        last_error = format!("{url}: missing data field");
    }

    Err(last_error)
}

fn build_custom_config_url(api_hint: &str) -> String {
    let trimmed = api_hint.trim().trim_end_matches('/');
    if trimmed.is_empty() {
        return DEFAULT_CUSTOM_CONFIG_URL.to_owned();
    }

    let lower = trimmed.to_ascii_lowercase();
    if lower.ends_with("/api/custom_app_config") {
        trimmed.to_owned()
    } else if lower.ends_with("/api") {
        format!("{trimmed}/custom_app_config")
    } else {
        format!("{trimmed}/api/custom_app_config")
    }
}

fn verify_cert_number(params: &PortableParams) -> Result<CertVerification, String> {
    let cert_code = params.certnum.trim();
    if cert_code.is_empty() {
        return Err("certno mode enabled but certnum is empty".to_owned());
    }

    let peer_id = Config::get_id();
    if peer_id.trim().is_empty() {
        return Err("local peer id is empty".to_owned());
    }

    let verify_url = build_cert_verify_url(&params.api);
    let body = json!({
        "cert_code": cert_code,
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
        return Err(format!("{verify_url}: success=true but customer_id is missing"));
    }

    let verified_peer_id = if parsed.mdesk_id.trim().is_empty() {
        peer_id.clone()
    } else {
        parsed.mdesk_id.trim().to_owned()
    };

    Ok(CertVerification {
        cert_code: cert_code.to_owned(),
        verify_url,
        peer_id,
        customer_id: customer_id.to_owned(),
        verified_peer_id,
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

fn call_agentnumupdate_with_cert(
    verification: &CertVerification,
    api_hint: &str,
) -> Result<String, String> {
    let url = build_agentnumupdate_url(
        api_hint,
        &verification.customer_id,
        &verification.verified_peer_id,
    );

    let client = Client::builder()
        .danger_accept_invalid_certs(true)
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|err| format!("http client build failed: {err}"))?;

    let mut last_error = String::from("agentnumupdate request was not attempted");
    for attempt in 1..=3 {
        let response = match client.get(&url).send() {
            Ok(response) => response,
            Err(err) => {
                last_error = format!("{url}: request failed on attempt {attempt}: {err}");
                std::thread::sleep(Duration::from_millis(500));
                continue;
            }
        };

        let status = response.status();
        let body = response.text().unwrap_or_default();
        if status.is_success() {
            return Ok(url);
        }

        last_error = format!(
            "{url}: unexpected status {} on attempt {} body={}",
            status, attempt, body
        );
        std::thread::sleep(Duration::from_millis(500));
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
        } else if lower.ends_with("/api/custom_app_config") {
            trimmed[..trimmed.len() - "/api/custom_app_config".len()].to_owned()
        } else if lower.ends_with("/api") {
            trimmed[..trimmed.len() - "/api".len()].to_owned()
        } else {
            trimmed
        }
    };

    // keep parity with Flutter behavior: admin host is converted to public base
    if let Some((scheme, host)) = base.split_once("://") {
        if let Some(stripped) = host.strip_prefix("admin.") {
            base = format!("{scheme}://{stripped}");
        }
    }

    format!("{base}/api/agentnumupdate/{customer_id}/{mdesk_id}?agentid=0")
}

fn print_portable_bootstrap(bootstrap: &PortableBootstrap) {
    let params = &bootstrap.params;
    println!("portable mode detected");
    println!("portable source={}", params.source);
    if let Some(user_id) = bootstrap.resolved_user_id.as_ref() {
        println!("portable user_id={user_id}");
    } else if let Some(user_id) = params.effective_user_id() {
        println!("portable user_id={user_id}");
    }
    if params.is_cert_mode() {
        println!(
            "portable certno_mode=true certnum={}",
            printable_or_dash(&params.certnum)
        );
    }
    if let Some(cert) = bootstrap.cert_verification.as_ref() {
        println!(
            "portable cert_verify success=yes customer_id={} peer_id={} verified_peer_id={} cert_code={} url={}",
            cert.customer_id,
            cert.peer_id,
            cert.verified_peer_id,
            cert.cert_code,
            cert.verify_url
        );
    }
    if let Some(url) = bootstrap.cert_agentnumupdate_url.as_ref() {
        println!("portable agentnumupdate success=yes url={url}");
    }
    if !params.agentid.is_empty() {
        println!("portable agent_id={}", params.agentid);
    }
    if !params.api.is_empty() {
        println!("portable api_hint={}", params.api);
    }
    if let Some(config) = bootstrap.custom_config.as_ref() {
        println!(
            "portable custom_config app_name={} title={} has_password={} has_encrypted_password={} has_logo={}",
            printable_or_dash(&config.app_name),
            printable_or_dash(&config.title),
            yes_no(!config.password.is_empty()),
            yes_no(!config.encrypted_password.is_empty()),
            yes_no(!config.logo_url.is_empty()),
        );
        if !config.description.is_empty() {
            println!("portable custom_config description_loaded=yes");
        }
    }
    if let Some(password) = bootstrap.effective_password.as_ref() {
        let applied_password = Config::get_permanent_password();
        println!(
        "portable login_password source={} length={} applied_length={} verification_method=use-permanent-password approve_mode=password",
            password.source.as_str(),
            password.value.chars().count(),
            applied_password.chars().count(),
        );
    }
    println!(
        "portable rendezvous_server={}",
        Config::get_rendezvous_server()
    );
    println!(
        "portable api_server={}",
        printable_or_dash(&Config::get_option("api-server"))
    );
    println!(
        "portable custom_id={} custom_agentid={}",
        printable_or_dash(&Config::get_option("custom-id")),
        printable_or_dash(&Config::get_option("custom-agentid")),
    );
}

fn printable_or_dash(value: &str) -> &str {
    if value.trim().is_empty() {
        "-"
    } else {
        value
    }
}

fn yes_no(value: bool) -> &'static str {
    if value {
        "yes"
    } else {
        "no"
    }
}

impl PasswordSource {
    fn as_str(self) -> &'static str {
        match self {
            PasswordSource::PortableArgument => "portable",
            PasswordSource::CustomConfig => "custom_config",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        build_agentnumupdate_url, build_cert_verify_url, build_custom_config_url,
        decode_portable_password,
        extract_portable_source_candidate, internal_mode_from_arg, parse_portable_params,
        resolve_effective_password, CustomConfigData, InternalMode, PasswordSource,
        PortableParams, DEFAULT_AGENTNUMUPDATE_BASE_URL, DEFAULT_CERT_VERIFY_URL,
        DEFAULT_CUSTOM_CONFIG_URL,
    };
    use hbb_common::base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};

    #[test]
    fn parses_filename_style_portable_args() {
        let parsed = parse_portable_params(
            "rustcli-host=mdesk.imedixerp.co.kr-api=https://admin.787.kr-id=admin-agentid=18.exe",
        );
        assert_eq!(parsed.host, "mdesk.imedixerp.co.kr");
        assert_eq!(parsed.api, "https://admin.787.kr");
        assert_eq!(parsed.id, "admin");
        assert_eq!(parsed.agentid, "18");
        assert!(parsed.is_portable());
        assert_eq!(parsed.effective_user_id(), Some("admin"));
    }

    #[test]
    fn certno_mode_forces_cert_user() {
        let parsed = parse_portable_params("rustcli-portable-certno=true-certnum=42847291.exe");
        assert_eq!(parsed.certno, "true");
        assert_eq!(parsed.certnum, "42847291");
        assert_eq!(parsed.effective_user_id(), Some("cert"));
    }

    #[test]
    fn custom_config_url_uses_expected_defaults() {
        assert_eq!(build_custom_config_url(""), DEFAULT_CUSTOM_CONFIG_URL);
        assert_eq!(
            build_custom_config_url("https://admin.787.kr"),
            "https://admin.787.kr/api/custom_app_config"
        );
        assert_eq!(
            build_custom_config_url("https://admin.787.kr/api"),
            "https://admin.787.kr/api/custom_app_config"
        );
        assert_eq!(
            build_custom_config_url("https://787.kr/api/custom_app_config"),
            "https://787.kr/api/custom_app_config"
        );
    }

    #[test]
    fn cert_verify_url_uses_expected_defaults() {
        assert_eq!(build_cert_verify_url(""), DEFAULT_CERT_VERIFY_URL);
        assert_eq!(
            build_cert_verify_url("https://admin.787.kr"),
            "https://admin.787.kr/api/certno/verify"
        );
        assert_eq!(
            build_cert_verify_url("https://admin.787.kr/api"),
            "https://admin.787.kr/api/certno/verify"
        );
        assert_eq!(
            build_cert_verify_url("https://admin.787.kr/api/certno/verify"),
            "https://admin.787.kr/api/certno/verify"
        );
    }

    #[test]
    fn agentnumupdate_url_uses_expected_defaults() {
        assert_eq!(
            build_agentnumupdate_url("", "imedix", "123456789"),
            format!(
                "{}/api/agentnumupdate/imedix/123456789?agentid=0",
                DEFAULT_AGENTNUMUPDATE_BASE_URL
            )
        );
        assert_eq!(
            build_agentnumupdate_url("https://admin.787.kr", "imedix", "123456789"),
            "https://787.kr/api/agentnumupdate/imedix/123456789?agentid=0"
        );
        assert_eq!(
            build_agentnumupdate_url("https://admin.787.kr/api", "imedix", "123456789"),
            "https://787.kr/api/agentnumupdate/imedix/123456789?agentid=0"
        );
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
    fn portable_password_overrides_custom_config_password() {
        let params = PortableParams {
            password: "chosen-secret".to_owned(),
            ..PortableParams::default()
        };
        let custom = CustomConfigData {
            password: "api-secret".to_owned(),
            ..CustomConfigData::default()
        };

        let resolved = resolve_effective_password(&params, Some(&custom)).unwrap();
        assert_eq!(resolved.value, "chosen-secret");
        assert_eq!(resolved.source, PasswordSource::PortableArgument);
    }

    #[test]
    fn custom_config_password_used_when_portable_missing() {
        let params = PortableParams::default();
        let custom = CustomConfigData {
            password: "api-secret".to_owned(),
            ..CustomConfigData::default()
        };

        let resolved = resolve_effective_password(&params, Some(&custom)).unwrap();
        assert_eq!(resolved.value, "api-secret");
        assert_eq!(resolved.source, PasswordSource::CustomConfig);
    }

    #[test]
    fn decodes_encoded_portable_password() {
        let plaintext = "MyPass1234";
        let key = b"rustdesk";
        let encrypted: Vec<u8> = plaintext
            .as_bytes()
            .iter()
            .enumerate()
            .map(|(index, value)| value ^ key[index % key.len()])
            .collect();
        let encoded = URL_SAFE_NO_PAD.encode(encrypted);

        assert_eq!(decode_portable_password(&encoded), plaintext);
    }

    #[test]
    fn recognizes_connection_manager_internal_args() {
        assert_eq!(
            internal_mode_from_arg(Some("--cm")),
            Some(InternalMode::ConnectionManager)
        );
        assert_eq!(
            internal_mode_from_arg(Some("--cm-no-ui")),
            Some(InternalMode::ConnectionManager)
        );
        assert_eq!(internal_mode_from_arg(Some("serve")), None);
    }

    #[test]
    fn extracts_portable_source_from_cmd_set_syntax() {
        let copied = r#"set "MDESK_APPNAME=rustcli-id=imedix-agentid=18-api=https://admin.787.kr.exe""#;
        let extracted = extract_portable_source_candidate(copied).unwrap();
        let parsed = parse_portable_params(&extracted);
        assert!(parsed.is_portable());
        assert_eq!(parsed.id, "imedix");
        assert_eq!(parsed.agentid, "18");
        assert_eq!(parsed.api, "https://admin.787.kr");
    }

    #[test]
    fn extracts_portable_source_from_powershell_env_syntax() {
        let copied =
            "$env:MDESK_APPNAME='rustcli-id=imedix-api=https://admin.787.kr-password=abc123.exe'";
        let extracted = extract_portable_source_candidate(copied).unwrap();
        let parsed = parse_portable_params(&extracted);
        assert!(parsed.is_portable());
        assert_eq!(parsed.id, "imedix");
        assert_eq!(parsed.api, "https://admin.787.kr");
        assert_eq!(parsed.password, "abc123");
    }

    #[test]
    fn extracts_certno_colon_from_clipboard_text() {
        let extracted = extract_portable_source_candidate("certno: 42847291").unwrap();
        let parsed = parse_portable_params(&extracted);
        assert!(parsed.is_cert_mode());
        assert_eq!(parsed.certno, "true");
        assert_eq!(parsed.certnum, "42847291");
        assert_eq!(parsed.effective_user_id(), Some("cert"));
    }

    #[test]
    fn ignores_non_portable_clipboard_text() {
        assert!(extract_portable_source_candidate("https://example.com/download").is_none());
    }
}
