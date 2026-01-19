use hbb_common::{config::Config, log, ResultType};
use serde::{Deserialize, Serialize};
use serde_json::json;

use super::create_http_client_with_url;

/// 기기 등록 요청 데이터
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceRegisterRequest {
    pub user_id: String,
    pub user_pkid: String,
    pub remote_id: String,
    pub alias: String,
    pub hostname: String,
    pub platform: String,
    pub uuid: String,
    pub version: String,
}

/// 기기 등록 응답 데이터
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceRegisterResponse {
    pub success: bool,
    #[serde(default)]
    pub message: String,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub data: Option<DeviceData>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceData {
    #[serde(default)]
    pub device_id: i64,
    #[serde(default)]
    pub remote_id: String,
    #[serde(default)]
    pub alias: String,
    #[serde(default)]
    pub registered_at: String,
}

impl Default for DeviceRegisterResponse {
    fn default() -> Self {
        Self {
            success: false,
            message: String::new(),
            error: None,
            data: None,
        }
    }
}

/// API 서버 URL을 가져옵니다
fn get_api_server() -> String {
    let api_server = Config::get_option("api-server");
    let custom_server = Config::get_option("custom-rendezvous-server");
    crate::common::get_api_server(api_server, custom_server)
}

/// access_token을 가져옵니다
fn get_access_token() -> String {
    hbb_common::config::LocalConfig::get_option("access_token")
}

/// 원격 기기를 API 서버에 등록
/// 
/// # Arguments
/// * `user_id` - 로그인된 유저 ID (username)
/// * `user_pkid` - 유저 고유 번호
/// * `remote_id` - 원격 ID (peer ID)
/// * `alias` - 사용자 지정 별칭
/// 
/// # Returns
/// * `Ok(DeviceRegisterResponse)` - 등록 성공/실패 응답
/// * `Err` - 네트워크 오류 등
pub fn register_device(
    user_id: &str,
    user_pkid: &str,
    remote_id: &str,
    alias: &str,
) -> ResultType<DeviceRegisterResponse> {
    let api_server = get_api_server();
    if api_server.is_empty() {
        log::error!("API server is not configured");
        return Ok(DeviceRegisterResponse {
            success: false,
            message: "API server is not configured".to_string(),
            error: Some("NO_API_SERVER".to_string()),
            data: None,
        });
    }

    let url = format!("{}/api/device/register", api_server);
    let client = create_http_client_with_url(&url);

    // 시스템 정보 수집
    let sysinfo = crate::get_sysinfo();
    let hostname = sysinfo["hostname"].as_str().unwrap_or_default();
    let platform = sysinfo["os"].as_str().unwrap_or_default();

    let request = DeviceRegisterRequest {
        user_id: user_id.to_string(),
        user_pkid: user_pkid.to_string(),
        remote_id: remote_id.to_string(),
        alias: alias.to_string(),
        hostname: hostname.to_string(),
        platform: platform.to_string(),
        uuid: crate::encode64(hbb_common::get_uuid()),
        version: crate::VERSION.to_string(),
    };

    log::info!("Registering device: remote_id={}, alias={}", remote_id, alias);
    log::debug!("Device register request: {:?}", &request);

    let access_token = get_access_token();
    
    let resp = client
        .post(&url)
        .header("Content-Type", "application/json")
        .header("Authorization", format!("Bearer {}", access_token))
        .json(&request)
        .send();

    match resp {
        Ok(response) => {
            let status = response.status();
            log::info!("Device register response status: {}", status);
            
            match response.json::<DeviceRegisterResponse>() {
                Ok(result) => {
                    if result.success {
                        log::info!("Device registered successfully: {}", remote_id);
                    } else {
                        log::warn!("Device registration failed: {:?}", result.error);
                    }
                    Ok(result)
                }
                Err(e) => {
                    log::error!("Failed to parse device register response: {}", e);
                    Ok(DeviceRegisterResponse {
                        success: false,
                        message: format!("Failed to parse response: {}", e),
                        error: Some("PARSE_ERROR".to_string()),
                        data: None,
                    })
                }
            }
        }
        Err(e) => {
            log::error!("Device registration request failed: {}", e);
            Ok(DeviceRegisterResponse {
                success: false,
                message: format!("Request failed: {}", e),
                error: Some("REQUEST_FAILED".to_string()),
                data: None,
            })
        }
    }
}

/// 기기 등록 해제
pub fn unregister_device(
    user_pkid: &str,
    remote_id: &str,
) -> ResultType<DeviceRegisterResponse> {
    let api_server = get_api_server();
    if api_server.is_empty() {
        log::error!("API server is not configured");
        return Ok(DeviceRegisterResponse {
            success: false,
            message: "API server is not configured".to_string(),
            error: Some("NO_API_SERVER".to_string()),
            data: None,
        });
    }

    let url = format!("{}/api/device/unregister", api_server);
    let client = create_http_client_with_url(&url);

    let body = json!({
        "user_pkid": user_pkid,
        "remote_id": remote_id,
    });

    log::info!("Unregistering device: remote_id={}", remote_id);

    let access_token = get_access_token();
    
    let resp = client
        .post(&url)
        .header("Content-Type", "application/json")
        .header("Authorization", format!("Bearer {}", access_token))
        .json(&body)
        .send();

    match resp {
        Ok(response) => {
            match response.json::<DeviceRegisterResponse>() {
                Ok(result) => {
                    if result.success {
                        log::info!("Device unregistered successfully: {}", remote_id);
                    } else {
                        log::warn!("Device unregistration failed: {:?}", result.error);
                    }
                    Ok(result)
                }
                Err(e) => {
                    log::error!("Failed to parse device unregister response: {}", e);
                    Ok(DeviceRegisterResponse {
                        success: false,
                        message: format!("Failed to parse response: {}", e),
                        error: Some("PARSE_ERROR".to_string()),
                        data: None,
                    })
                }
            }
        }
        Err(e) => {
            log::error!("Device unregistration request failed: {}", e);
            Ok(DeviceRegisterResponse {
                success: false,
                message: format!("Request failed: {}", e),
                error: Some("REQUEST_FAILED".to_string()),
                data: None,
            })
        }
    }
}

/// 등록된 기기 목록 조회
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceListResponse {
    pub success: bool,
    #[serde(default)]
    pub message: String,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub data: Vec<RegisteredDevice>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegisteredDevice {
    pub device_id: i64,
    pub remote_id: String,
    pub alias: String,
    pub hostname: String,
    pub platform: String,
    #[serde(default)]
    pub is_online: bool,
    #[serde(default)]
    pub last_online_at: Option<String>,
    pub registered_at: String,
}

impl Default for DeviceListResponse {
    fn default() -> Self {
        Self {
            success: false,
            message: String::new(),
            error: None,
            data: Vec::new(),
        }
    }
}

pub fn get_registered_devices(user_pkid: &str) -> ResultType<DeviceListResponse> {
    let api_server = get_api_server();
    if api_server.is_empty() {
        log::error!("API server is not configured");
        return Ok(DeviceListResponse {
            success: false,
            message: "API server is not configured".to_string(),
            error: Some("NO_API_SERVER".to_string()),
            data: Vec::new(),
        });
    }

    let url = format!("{}/api/device/list?user_pkid={}", api_server, user_pkid);
    let client = create_http_client_with_url(&url);

    log::info!("Getting registered devices for user_pkid={}", user_pkid);

    let access_token = get_access_token();
    
    let resp = client
        .get(&url)
        .header("Authorization", format!("Bearer {}", access_token))
        .send();

    match resp {
        Ok(response) => {
            match response.json::<DeviceListResponse>() {
                Ok(result) => {
                    log::info!("Got {} registered devices", result.data.len());
                    Ok(result)
                }
                Err(e) => {
                    log::error!("Failed to parse device list response: {}", e);
                    Ok(DeviceListResponse {
                        success: false,
                        message: format!("Failed to parse response: {}", e),
                        error: Some("PARSE_ERROR".to_string()),
                        data: Vec::new(),
                    })
                }
            }
        }
        Err(e) => {
            log::error!("Device list request failed: {}", e);
            Ok(DeviceListResponse {
                success: false,
                message: format!("Request failed: {}", e),
                error: Some("REQUEST_FAILED".to_string()),
                data: Vec::new(),
            })
        }
    }
}
