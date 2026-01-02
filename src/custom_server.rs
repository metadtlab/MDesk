use hbb_common::{
    bail,
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _},
    sodiumoxide::crypto::sign,
    ResultType,
};
use serde_derive::{Deserialize, Serialize};

#[derive(Debug, PartialEq, Default, Serialize, Deserialize, Clone)]
pub struct CustomServer {
    #[serde(default)]
    pub key: String,
    #[serde(default)]
    pub host: String,
    #[serde(default)]
    pub api: String,
    #[serde(default)]
    pub relay: String,
    #[serde(default)]
    pub password: String,
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub agentid: String,
}

fn get_custom_server_from_config_string(s: &str) -> ResultType<CustomServer> {
    let tmp: String = s.chars().rev().collect();
    const PK: &[u8; 32] = &[
        88, 168, 68, 104, 60, 5, 163, 198, 165, 38, 12, 85, 114, 203, 96, 163, 70, 48, 0, 131, 57,
        12, 46, 129, 83, 17, 84, 193, 119, 197, 130, 103,
    ];
    let pk = sign::PublicKey(*PK);
    let data = URL_SAFE_NO_PAD.decode(tmp)?;
    if let Ok(lic) = serde_json::from_slice::<CustomServer>(&data) {
        return Ok(lic);
    }
    if let Ok(data) = sign::verify(&data, &pk) {
        Ok(serde_json::from_slice::<CustomServer>(&data)?)
    } else {
        bail!("sign:verify failed");
    }
}

pub fn get_custom_server_from_string(s: &str) -> ResultType<CustomServer> {
    let s = if s.to_lowercase().ends_with(".exe.exe") {
        &s[0..s.len() - 8]
    } else if s.to_lowercase().ends_with(".exe") {
        &s[0..s.len() - 4]
    } else {
        s
    };
    /*
     * The following code tokenizes the file name based on commas and
     * extracts relevant parts sequentially.
     *
     * host= is expected to be the first part.
     *
     * Since Windows renames files adding (1), (2) etc. before the .exe
     * in case of duplicates, which causes the host or key values to be
     * garbled.
     *
     * This allows using a ',' (comma) symbol as a final delimiter.
     */
    if s.to_lowercase().contains("host=") || s.to_lowercase().contains("p=[") || s.to_lowercase().contains("portable") || s.to_lowercase().contains("id=") {
        let find_host = s.to_lowercase().find("host=");
        let find_p = s.to_lowercase().find("p=[");
        let find_portable = s.to_lowercase().find("portable");
        let find_id = s.to_lowercase().find("id=");
        let start_pos = [find_host, find_p, find_portable, find_id]
            .iter()
            .filter_map(|&x| x)
            .min()
            .unwrap_or(0);
        let stripped = &s[start_pos..s.len()];
        let strs: Vec<String> = stripped
            .replace("-", ",")
            .split(",")
            .map(|x| x.to_string())
            .collect();
        let mut host = String::default();
        let mut key = String::default();
        let mut api = String::default();
        let mut relay = String::default();
        let mut password = String::default();
        let mut id = String::default();
        let mut agentid = String::default();
        for el in strs {
            let el_lower = el.to_lowercase();
            if el_lower.starts_with("host=") {
                host = el.chars().skip(5).collect();
            }
            if el_lower.starts_with("key=") {
                key = el.chars().skip(4).collect();
            }
            if el_lower.starts_with("api=") {
                api = el.chars().skip(4).collect();
            }
            if el_lower.starts_with("relay=") {
                relay = el.chars().skip(6).collect();
            }
            // agentid= 먼저 체크 (id= 보다 먼저)
            if el_lower.starts_with("agentid=") {
                agentid = el.chars().skip(8).collect();
            } else if el_lower.starts_with("id=") {
                id = el.chars().skip(3).collect();
            }
            if el_lower.starts_with("password=") {
                password = el.chars().skip(9).collect();
            }
            if el_lower.starts_with("p=[") && el_lower.ends_with("]") {
                let encoded = el.chars().skip(3).take(el.len() - 4).collect::<String>();
                password = decode_password(&encoded);
            }
            // p=1234 형태 지원 추가
            if el_lower.starts_with("p=") && !el_lower.starts_with("p=[") {
                password = el.chars().skip(2).collect();
            }
        }
        return Ok(CustomServer {
            host,
            key,
            api,
            relay,
            password,
            id,
            agentid,
        });
    } else {
        let s = s
            .replace("-licensed---", "--")
            .replace("-licensed--", "--")
            .replace("-licensed-", "--");
        let strs = s.split("--");
        for s in strs {
            if let Ok(lic) = get_custom_server_from_config_string(s.trim()) {
                return Ok(lic);
            } else if s.contains("(") {
                // https://github.com/rustdesk/rustdesk/issues/4162
                for s in s.split("(") {
                    if let Ok(lic) = get_custom_server_from_config_string(s.trim()) {
                        return Ok(lic);
                    }
                }
            }
        }
    }
    bail!("Failed to parse");
}

pub fn decode_password_external(s: &str) -> String {
    decode_password(s)
}

fn decode_password(s: &str) -> String {
    // 1. Base64 디코딩 시도
    if let Ok(decoded) = URL_SAFE_NO_PAD.decode(s).or_else(|_| {
        use hbb_common::base64::{engine::general_purpose::STANDARD, Engine};
        STANDARD.decode(s)
    }) {
        // 2. 간단한 XOR 복호화 (키: 'rustdesk')
        let key = b"rustdesk";
        let decrypted: Vec<u8> = decoded
            .iter()
            .enumerate()
            .map(|(i, &b)| b ^ key[i % key.len()])
            .collect();
        String::from_utf8(decrypted).unwrap_or_else(|_| s.to_string())
    } else {
        // 디코딩 실패 시 평문으로 간주
        s.to_string()
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn test_filename_license_string() {
        assert!(get_custom_server_from_string("rustdesk.exe").is_err());
        assert!(get_custom_server_from_string("rustdesk").is_err());
        assert_eq!(
            get_custom_server_from_string("rustdesk-host=server.example.net.exe").unwrap(),
            CustomServer {
                host: "server.example.net".to_owned(),
                key: "".to_owned(),
                api: "".to_owned(),
                relay: "".to_owned(),
            }
        );
        assert_eq!(
            get_custom_server_from_string("rustdesk-host=server.example.net,.exe").unwrap(),
            CustomServer {
                host: "server.example.net".to_owned(),
                key: "".to_owned(),
                api: "".to_owned(),
                relay: "".to_owned(),
            }
        );
        // key in these tests is "foobar.,2" base64 encoded
        assert_eq!(
            get_custom_server_from_string(
                "rustdesk-host=server.example.net,api=abc,key=Zm9vYmFyLiwyCg==.exe"
            )
            .unwrap(),
            CustomServer {
                host: "server.example.net".to_owned(),
                key: "Zm9vYmFyLiwyCg==".to_owned(),
                api: "abc".to_owned(),
                relay: "".to_owned(),
            }
        );
        assert_eq!(
            get_custom_server_from_string(
                "rustdesk-host=server.example.net,key=Zm9vYmFyLiwyCg==,.exe"
            )
            .unwrap(),
            CustomServer {
                host: "server.example.net".to_owned(),
                key: "Zm9vYmFyLiwyCg==".to_owned(),
                api: "".to_owned(),
                relay: "".to_owned(),
            }
        );
        assert_eq!(
            get_custom_server_from_string(
                "rustdesk-host=server.example.net,key=Zm9vYmFyLiwyCg==,relay=server.example.net.exe"
            )
            .unwrap(),
            CustomServer {
                host: "server.example.net".to_owned(),
                key: "Zm9vYmFyLiwyCg==".to_owned(),
                api: "".to_owned(),
                relay: "server.example.net".to_owned(),
            }
        );
        assert_eq!(
            get_custom_server_from_string(
                "rustdesk-Host=server.example.net,Key=Zm9vYmFyLiwyCg==,RELAY=server.example.net.exe"
            )
            .unwrap(),
            CustomServer {
                host: "server.example.net".to_owned(),
                key: "Zm9vYmFyLiwyCg==".to_owned(),
                api: "".to_owned(),
                relay: "server.example.net".to_owned(),
            }
        );
        let lic = CustomServer {
            host: "1.1.1.1".to_owned(),
            key: "5Qbwsde3unUcJBtrx9ZkvUmwFNoExHzpryHuPUdqlWM=".to_owned(),
            api: "".to_owned(),
            relay: "".to_owned(),
        };
        assert_eq!(
            get_custom_server_from_string("rustdesk-licensed-0nI900VsFHZVBVdIlncwpHS4V0bOZ0dtVldrpVO4JHdCp0YV5WdzUGZzdnYRVjI6ISeltmIsISMuEjLx4SMiojI0N3boJye.exe")
                .unwrap(), lic);
        assert_eq!(
            get_custom_server_from_string("rustdesk-licensed-0nI900VsFHZVBVdIlncwpHS4V0bOZ0dtVldrpVO4JHdCp0YV5WdzUGZzdnYRVjI6ISeltmIsISMuEjLx4SMiojI0N3boJye(1).exe")
                .unwrap(), lic);
        assert_eq!(
            get_custom_server_from_string("rustdesk--0nI900VsFHZVBVdIlncwpHS4V0bOZ0dtVldrpVO4JHdCp0YV5WdzUGZzdnYRVjI6ISeltmIsISMuEjLx4SMiojI0N3boJye(1).exe")
                .unwrap(), lic);
        assert_eq!(
            get_custom_server_from_string("rustdesk-licensed-0nI900VsFHZVBVdIlncwpHS4V0bOZ0dtVldrpVO4JHdCp0YV5WdzUGZzdnYRVjI6ISeltmIsISMuEjLx4SMiojI0N3boJye (1).exe")
                .unwrap(), lic);
        assert_eq!(
            get_custom_server_from_string("rustdesk-licensed-0nI900VsFHZVBVdIlncwpHS4V0bOZ0dtVldrpVO4JHdCp0YV5WdzUGZzdnYRVjI6ISeltmIsISMuEjLx4SMiojI0N3boJye (1) (2).exe")
                .unwrap(), lic);
        assert_eq!(
            get_custom_server_from_string("rustdesk-licensed-0nI900VsFHZVBVdIlncwpHS4V0bOZ0dtVldrpVO4JHdCp0YV5WdzUGZzdnYRVjI6ISeltmIsISMuEjLx4SMiojI0N3boJye--abc.exe")
                .unwrap(), lic);
        assert_eq!(
            get_custom_server_from_string("rustdesk-licensed--0nI900VsFHZVBVdIlncwpHS4V0bOZ0dtVldrpVO4JHdCp0YV5WdzUGZzdnYRVjI6ISeltmIsISMuEjLx4SMiojI0N3boJye--.exe")
                .unwrap(), lic);
        assert_eq!(
            get_custom_server_from_string("rustdesk-licensed---0nI900VsFHZVBVdIlncwpHS4V0bOZ0dtVldrpVO4JHdCp0YV5WdzUGZzdnYRVjI6ISeltmIsISMuEjLx4SMiojI0N3boJye--.exe")
                .unwrap(), lic);
        assert_eq!(
            get_custom_server_from_string("rustdesk-licensed--0nI900VsFHZVBVdIlncwpHS4V0bOZ0dtVldrpVO4JHdCp0YV5WdzUGZzdnYRVjI6ISeltmIsISMuEjLx4SMiojI0N3boJye--.exe")
                .unwrap(), lic);
    }
}
