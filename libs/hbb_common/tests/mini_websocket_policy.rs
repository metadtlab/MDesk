#![cfg(windows)]

use hbb_common::config::{self, keys, Config, Config2};
use std::{fs, process::Command};

// Use separate processes and an isolated profile: the Mini-only flag must not
// affect a later installed client, or other tests using global config state.
#[test]
fn mini_websocket_policy_is_process_local() {
    const MODE: &str = "MDESK_WS_POLICY_TEST_MODE";
    const APP: &str = "MDESK_WS_POLICY_TEST_APP";
    if let Ok(mode) = std::env::var(MODE) {
        let name = std::env::var(APP).unwrap();
        assert!(name.starts_with("mdesk-ws-policy-"));
        *config::APP_NAME.write().unwrap() = name.clone();
        let file = Config2::file();
        assert_eq!(file.parent().unwrap().parent().unwrap().file_name().unwrap(), name.as_str());
        config::apply_product_default_settings();
        let option = keys::OPTION_ALLOW_WEBSOCKET;
        if mode == "mini" {
            assert!(!config::use_ws(), "installed product default must be off");
            Config::set_option(option.into(), "N".into());
            Config::set_option("custom-rendezvous-server".into(), "787.kr".into());
            let saved = fs::read(Config2::file()).unwrap();
            config::OVERWRITE_SETTINGS.write().unwrap().insert(option.into(), "N".into());
            config::require_websocket_for_process();
            config::apply_product_default_settings();
            assert!(config::use_ws(), "Mini must override saved and custom N");
            assert_eq!(hbb_common::websocket::check_ws("787.kr:21116"), "wss://787.kr/ws/id");
            assert_eq!(hbb_common::websocket::check_ws("787.kr:21117"), "wss://787.kr/ws/relay");
            assert_eq!(fs::read(Config2::file()).unwrap(), saved, "forcing WS must not persist it");
        } else {
            assert_eq!(Config::get_option(option), "N");
            assert!(!config::use_ws(), "installed process must not inherit Mini's policy");
            Config::set_option(option.into(), "Y".into());
            assert!(config::use_ws(), "installed users can still opt in");
            Config::set_option(option.into(), "N".into());
            assert!(!config::use_ws(), "installed users can opt out again");
        }
        return;
    }
    let name = format!("mdesk-ws-policy-{}-{}", std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos());
    // directories_next uses Windows Known Folders, ignoring APPDATA overrides.
    // A unique application name isolates the real resolved config directory.
    *config::APP_NAME.write().unwrap() = name.clone();
    let profile = Config2::file().parent().unwrap().parent().unwrap().to_path_buf();
    assert_eq!(profile.file_name().unwrap(), name.as_str());
    assert!(!profile.exists());
    for mode in ["mini", "installed"] {
        let output = Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "mini_websocket_policy_is_process_local", "--nocapture"])
            .env(MODE, mode)
            .env(APP, &name)
            .output().unwrap();
        assert!(output.status.success(), "{}: {}\n{}", mode,
            String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr));
    }
    // Packaged Windows apps can virtualize Roaming paths. Delete only these
    // known test files and empty directories, without recursive deletion.
    for file in [Config2::file(), Config::file()] {
        if file.exists() {
            fs::remove_file(file).unwrap();
        }
    }
    fs::remove_dir(Config2::file().parent().unwrap()).unwrap();
    fs::remove_dir(profile).unwrap();
}
