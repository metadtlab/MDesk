//! Compatibility for the retired MDesk ID/relay hostname.
use std::collections::HashMap;

pub const SERVER_HOST: &str = "787.kr";
pub const API_URL: &str = "https://admin.787.kr";
const LEGACY_HOST: &str = "mdesk.imedixerp.co.kr";

/// Replace only the exact legacy authority; retain custom ports and URL suffixes.
/// Unrelated servers, credentials and hostname suffix lookalikes are untouched.
pub fn canonical_server(value: &str) -> String {
    let trimmed = value.trim();
    let offset = trimmed.find("://").map_or(0, |i| i + 3);
    let rest = &trimmed[offset..];
    let authority_end = rest.find(|c| matches!(c, '/' | '?' | '#')).unwrap_or(rest.len());
    if rest[..authority_end].contains('@') {
        return value.to_owned();
    }
    let end = rest.find(|c| matches!(c, ':' | '/' | '?' | '#')).unwrap_or(rest.len());
    if rest[..end].eq_ignore_ascii_case(LEGACY_HOST) {
        format!("{}{}{}", &trimmed[..offset], SERVER_HOST, &rest[end..])
    } else {
        value.to_owned()
    }
}

pub fn canonical_option(key: &str, value: &str) -> String {
    match key {
        "custom-rendezvous-server" | "relay-server" => canonical_server(value),
        "rendezvous-servers" => value.split(',').map(canonical_server).collect::<Vec<_>>().join(","),
        _ => value.to_owned(),
    }
}

pub fn migrate_options(options: &mut HashMap<String, String>) -> bool {
    let mut changed = false;
    for (key, value) in options.iter_mut() {
        let canonical = canonical_option(key, value);
        if canonical != *value {
            *value = canonical;
            changed = true;
        }
    }
    changed
}

pub fn websocket_scheme(host: &str, api: &str) -> &'static str {
    // MDesk's public proxy requires TLS even when the optional API field is blank.
    if host.eq_ignore_ascii_case(SERVER_HOST)
        || host.eq_ignore_ascii_case("www.787.kr")
        || api.starts_with("https")
    {
        "wss"
    } else {
        "ws"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exact_legacy_authorities_only() {
        for (input, expected) in [
            ("mdesk.imedixerp.co.kr", "787.kr"),
            (" MDESK.IMEDIXERP.CO.KR:22117 ", "787.kr:22117"),
            ("wss://mdesk.imedixerp.co.kr/ws/relay", "wss://787.kr/ws/relay"),
            ("wss://mdesk.imedixerp.co.kr:443/ws/id?a=b", "wss://787.kr:443/ws/id?a=b"),
            ("admin.787.kr", "admin.787.kr"),
            ("other.example:21117", "other.example:21117"),
            ("mdesk.imedixerp.co.kr.example", "mdesk.imedixerp.co.kr.example"),
            ("mdesk.imedixerp.co.kr@other.example", "mdesk.imedixerp.co.kr@other.example"),
            ("wss://mdesk.imedixerp.co.kr:secret@other.example/ws", "wss://mdesk.imedixerp.co.kr:secret@other.example/ws"),
            ("[::1]:21117", "[::1]:21117"),
        ] {
            assert_eq!(canonical_server(input), expected);
            assert_eq!(canonical_server(expected), expected);
        }
    }

    #[test]
    fn saved_options_preserve_api_and_keys() {
        let mut options = HashMap::from([
            ("relay-server".into(), LEGACY_HOST.into()),
            ("custom-rendezvous-server".into(), format!("{}:21116", LEGACY_HOST)),
            ("rendezvous-servers".into(), format!("{},other.example", LEGACY_HOST)),
            ("api-server".into(), API_URL.into()),
            ("key".into(), "existing-key".into()),
            ("other".into(), LEGACY_HOST.into()),
        ]);
        assert!(migrate_options(&mut options));
        assert_eq!(options["relay-server"], SERVER_HOST);
        assert_eq!(options["custom-rendezvous-server"], "787.kr:21116");
        assert_eq!(options["rendezvous-servers"], "787.kr,other.example");
        assert_eq!(options["api-server"], API_URL);
        assert_eq!(options["key"], "existing-key");
        assert_eq!(options["other"], LEGACY_HOST);
        assert!(!migrate_options(&mut options));
    }

    #[test]
    fn public_mdesk_uses_tls_without_api_option() {
        assert_eq!(websocket_scheme("787.kr", ""), "wss");
        assert_eq!(websocket_scheme("787.kr", "http://private-api"), "wss");
        assert_eq!(websocket_scheme("www.787.kr", API_URL), "wss");
        assert_eq!(websocket_scheme("private.example", ""), "ws");
        assert_eq!(websocket_scheme("private.example", "https://private-api"), "wss");
    }
}
