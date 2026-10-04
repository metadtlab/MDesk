//! Access credentials for biometric mobile sessions must not reach local TOML.
use std::sync::RwLock;

static ACCESS_TOKEN: RwLock<String> = RwLock::new(String::new());

pub fn get() -> String {
    ACCESS_TOKEN.read().unwrap().clone()
}

pub fn set(token: String) {
    *ACCESS_TOKEN.write().unwrap() = token;
}

#[cfg(test)]
mod tests {
    #[test]
    fn cold_process_requires_a_new_biometric_unlock() {
        const CHILD: &str = "MDESK_BIOMETRIC_TOKEN_TEST_CHILD";
        if std::env::var_os(CHILD).is_some() {
            assert!(super::get().is_empty());
            return;
        }
        super::set("session-access".to_owned());
        let name = concat!(
            module_path!(),
            "::cold_process_requires_a_new_biometric_unlock"
        );
        let (_, test_path) = name.split_once("::").unwrap();
        let child = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", test_path])
            .env(CHILD, "1")
            .output()
            .unwrap();
        assert!(
            child.status.success(),
            "{}",
            String::from_utf8_lossy(&child.stdout)
        );
        assert!(String::from_utf8_lossy(&child.stdout).contains("1 passed;"));
        super::set(String::new());
    }
}
