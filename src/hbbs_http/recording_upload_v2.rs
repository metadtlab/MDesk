use hbb_common::{
    anyhow, bail,
    config::{Config, LocalConfig},
    ResultType,
};
use reqwest::blocking::multipart::{Form, Part};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{
    fs::File,
    path::{Path, PathBuf},
    time::Duration,
};
use uuid::Uuid;

const MAX_RECORDING_BYTES: u64 = 2 * 1024 * 1024 * 1024;
pub const UPLOAD_TIMEOUT: Duration = Duration::from_secs(2 * 60 * 60);

#[derive(Clone, Debug)]
pub struct RecordingUploadRequest<'a> {
    pub source_connection_id: &'a str,
    pub ticket: &'a str,
    pub title: &'a str,
    pub work_content: &'a str,
    pub file_path: &'a Path,
}

#[derive(Clone, Debug, Deserialize)]
pub struct RecordingUploadResponse {
    pub id: String,
    pub upload_id: String,
    pub source_connection_id: String,
    #[serde(default)]
    pub idempotent: bool,
}

/// Uploads a finalized local recording with the controller's interactive
/// RustDesk bearer. The file part streams from disk; it is never buffered into
/// a single in-memory byte array.
pub fn upload_recording(
    request: RecordingUploadRequest<'_>,
) -> ResultType<RecordingUploadResponse> {
    validate_request(&request)?;

    let access_token = LocalConfig::get_option("access_token");
    if access_token.trim().is_empty() {
        bail!("로그인 정보가 없어 녹화 영상을 서버에 저장할 수 없습니다. 로컬 원본은 유지됩니다.");
    }

    let api_server = crate::common::get_api_server(
        Config::get_option("api-server"),
        Config::get_option("custom-rendezvous-server"),
    );
    if api_server.trim().is_empty() {
        bail!("API 서버 주소가 없어 녹화 영상을 업로드하지 못했습니다. 로컬 원본은 유지됩니다.");
    }
    crate::common::validate_secure_capability_url(&api_server).map_err(|err| {
        anyhow::anyhow!(
            "로그인 토큰과 연결 티켓을 보호할 수 없는 API 주소입니다: {err}. 로컬 원본은 유지됩니다."
        )
    })?;

    let metadata = request
        .file_path
        .metadata()
        .map_err(|err| anyhow::anyhow!("녹화 파일을 열 수 없습니다: {err}"))?;
    if !metadata.is_file() || metadata.len() == 0 {
        bail!("녹화 파일이 비어 있거나 올바른 파일이 아닙니다.");
    }
    if metadata.len() > MAX_RECORDING_BYTES {
        bail!("녹화 파일이 서버 업로드 제한(2 GiB)을 초과했습니다. 로컬 원본은 유지됩니다.");
    }

    let filename = request
        .file_path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| anyhow::anyhow!("녹화 파일 이름을 확인할 수 없습니다."))?;
    let content_type = recording_content_type(request.file_path)?;
    let upload_id = deterministic_upload_id(request.source_connection_id, request.file_path);
    let file = File::open(request.file_path)?;
    let file_part = Part::reader_with_length(file, metadata.len())
        .file_name(filename.to_owned())
        .mime_str(content_type)?;
    let form = Form::new()
        .text("upload_id", upload_id.clone())
        .text(
            "source_connection_id",
            request.source_connection_id.to_owned(),
        )
        .text("ticket", request.ticket.to_owned())
        .text("title", request.title.trim().to_owned())
        .text("work_content", request.work_content.trim().to_owned())
        .part("file", file_part);

    // Recording upload carries both a user bearer and a connection capability.
    // It must never use the legacy invalid-certificate fallback/cache.
    let client = super::http_client::create_secure_http_client().map_err(|err| {
        anyhow::anyhow!("보안 업로드 연결을 준비하지 못했습니다: {err}. 로컬 원본은 유지됩니다.")
    })?;
    let response = client
        .post(format!(
            "{}/api/recordings",
            api_server.trim_end_matches('/')
        ))
        .bearer_auth(access_token.trim())
        .header("X-MDesk-Recording-Protocol", "1")
        .multipart(form)
        .timeout(UPLOAD_TIMEOUT)
        .send()?;
    let status = response.status();
    let response_body = response.text()?;
    if !status.is_success() {
        let message = server_error_message(&response_body);
        bail!(
            "녹화 영상 서버 저장에 실패했습니다 (HTTP {}): {} 로컬 원본은 유지됩니다.",
            status.as_u16(),
            message
        );
    }
    let parsed: RecordingUploadResponse = serde_json::from_str(&response_body)?;
    if Uuid::parse_str(&parsed.id).is_err()
        || parsed.upload_id != upload_id
        || parsed.source_connection_id != request.source_connection_id
    {
        bail!(
            "녹화 영상 서버 응답의 연결 정보가 요청과 일치하지 않습니다. 로컬 원본은 유지됩니다."
        );
    }
    Ok(parsed)
}

fn validate_request(request: &RecordingUploadRequest<'_>) -> ResultType<()> {
    Uuid::parse_str(request.source_connection_id).map_err(|_| {
        anyhow::anyhow!("검증된 연결 식별자가 없어 녹화 영상을 업로드할 수 없습니다.")
    })?;
    if request.ticket.trim().is_empty() {
        bail!("검증된 연결 티켓이 없어 녹화 영상을 업로드할 수 없습니다.");
    }
    let title_len = request.title.trim().chars().count();
    if !(1..=120).contains(&title_len) {
        bail!("영상 제목은 1자 이상 120자 이하로 입력해 주세요.");
    }
    if request.work_content.trim().chars().count() > 2000 {
        bail!("작업 내용은 2000자 이하로 입력해 주세요.");
    }
    Ok(())
}

fn recording_content_type(path: &Path) -> ResultType<&'static str> {
    match path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase()
        .as_str()
    {
        "webm" => Ok("video/webm"),
        "mkv" => Ok("video/x-matroska"),
        "mp4" => Ok("video/mp4"),
        _ => bail!("서버에 저장할 수 있는 녹화 형식은 WebM, MKV, MP4입니다."),
    }
}

/// The idempotency key stays stable across UI retries and process-local upload
/// timeouts without persisting a bearer or connection ticket to disk.
pub fn deterministic_upload_id(source_connection_id: &str, file_path: &Path) -> String {
    let normalized_path = file_path
        .canonicalize()
        .unwrap_or_else(|_| PathBuf::from(file_path));
    let mut digest = Sha256::new();
    digest.update(b"mdesk-recording-upload-v1\0");
    digest.update(source_connection_id.as_bytes());
    digest.update(b"\0");
    digest.update(normalized_path.to_string_lossy().as_bytes());
    let hash = digest.finalize();
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&hash[..16]);
    // RFC 4122 variant + version 5-shaped deterministic UUID. The bytes are a
    // SHA-256 prefix rather than UUID's SHA-1 namespace construction.
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Uuid::from_bytes(bytes).to_string()
}

fn server_error_message(body: &str) -> String {
    let parsed = serde_json::from_str::<serde_json::Value>(body).ok();
    let message = parsed
        .as_ref()
        .and_then(|value| {
            value
                .get("message")
                .or_else(|| value.get("error"))
                .and_then(|value| value.as_str())
        })
        .unwrap_or(body)
        .trim();
    let mut shortened: String = message.chars().take(500).collect();
    if shortened.is_empty() {
        shortened = "서버 응답을 확인할 수 없습니다.".to_owned();
    }
    shortened
}

#[cfg(test)]
mod tests {
    use super::{deterministic_upload_id, recording_content_type};
    use std::path::Path;

    #[test]
    fn upload_id_is_stable_and_scoped_to_connection() {
        let path = Path::new("recordings/session.webm");
        let first = deterministic_upload_id("45bc3c20-4bc4-4ea5-945d-3b62c061d04b", path);
        let retry = deterministic_upload_id("45bc3c20-4bc4-4ea5-945d-3b62c061d04b", path);
        let other = deterministic_upload_id("65b6fd3a-ded4-4979-9d9b-06c3714e6ae9", path);
        assert_eq!(first, retry);
        assert_ne!(first, other);
        assert!(uuid::Uuid::parse_str(&first).is_ok());
    }

    #[test]
    fn only_supported_video_containers_are_uploaded() {
        assert_eq!(
            recording_content_type(Path::new("screen.WEBM")).unwrap(),
            "video/webm"
        );
        assert!(recording_content_type(Path::new("screen.avi")).is_err());
    }

    #[test]
    fn authenticated_upload_requires_https_except_loopback() {
        assert!(crate::common::validate_secure_capability_url("https://admin.787.kr").is_ok());
        assert!(crate::common::validate_secure_capability_url("http://admin.787.kr").is_err());
    }
}
