//! Service-owned registrations, deliberately separate from per-session config sync.
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs::{self, DirBuilder, OpenOptions},
    io::{self, Write},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};

const MAX_REGISTRY_BYTES: usize = 1024 * 1024;
static NEXT_FILE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug, Serialize, Deserialize)]
pub enum RegistryMessage {
    Get,
    Set(String),
    Migrate(String),
    Value(Option<String>),
    Error(String),
}

impl RegistryMessage {
    pub fn allowed(&self, may_write: bool) -> bool {
        match self {
            Self::Get => true,
            Self::Set(_) | Self::Migrate(_) => may_write,
            Self::Value(_) | Self::Error(_) => false,
        }
    }
}

pub fn validate(json: &str) -> io::Result<String> {
    if json.len() > MAX_REGISTRY_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "registration list is too large",
        ));
    }
    // Keep the Flutter schema and encrypted passwords intact. Do not include
    // serde errors (which may contain input values) in logs or IPC responses.
    let users: Vec<BTreeMap<String, String>> = serde_json::from_str(json)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid registration list"))?;
    if users.iter().any(|u| {
        u.get("id").map_or(true, |id| id.trim().is_empty()) || !u.contains_key("connectionPassword")
    }) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid registration fields",
        ));
    }
    serde_json::to_string(&users).map_err(io::Error::other)
}

pub struct RegistryStore {
    path: PathBuf,
}

impl RegistryStore {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    fn load(&self) -> io::Result<Option<String>> {
        match fs::read_to_string(&self.path) {
            Ok(json) => validate(&json).map(Some),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e),
        }
    }

    fn save(&self, json: &str) -> io::Result<()> {
        let parent = self.path.parent().ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "missing registration directory",
            )
        })?;
        DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(parent)?;
        let temporary = parent.join(format!(
            ".registered-users-{}-{}.tmp",
            std::process::id(),
            NEXT_FILE.fetch_add(1, Ordering::Relaxed)
        ));
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)?;
        let result = (|| {
            file.write_all(json.as_bytes())?;
            file.sync_all()?;
            fs::rename(&temporary, &self.path)?;
            fs::File::open(parent)?.sync_all()
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result
    }

    // The service serializes calls with its registry mutex. An existing empty
    // list is a tombstone: stale user/greeter files must never restore deletions.
    pub fn apply(&self, request: RegistryMessage) -> io::Result<Option<String>> {
        match request {
            RegistryMessage::Get => self.load(),
            RegistryMessage::Migrate(json) => {
                if let Some(current) = self.load()? {
                    return Ok(Some(current));
                }
                self.apply(RegistryMessage::Set(json))
            }
            RegistryMessage::Set(json) => {
                let json = validate(&json)?;
                self.save(&json)?;
                Ok(Some(json))
            }
            _ => Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid registration request",
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    const OLD: &str =
        r#"[{"id":"operator","name":"Operator","connectionPassword":"00encrypted-old"}]"#;
    const NEW: &str =
        r#"[{"id":"operator","name":"Operator","connectionPassword":"00encrypted-new"}]"#;

    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let dir = std::env::temp_dir().join(format!(
                "mdesk-registry-test-{}-{}",
                std::process::id(),
                NEXT_FILE.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&dir).unwrap();
            Self(dir)
        }
        fn store(&self) -> RegistryStore {
            RegistryStore::new(self.0.join("config/users.json"))
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }

    #[test]
    fn migration_survives_restart_without_user_profile() {
        let fixture = Fixture::new();
        assert_eq!(fixture.store().apply(RegistryMessage::Get).unwrap(), None);
        fixture
            .store()
            .apply(RegistryMessage::Migrate(OLD.into()))
            .unwrap();
        assert_eq!(
            fixture.store().apply(RegistryMessage::Get).unwrap(),
            Some(validate(OLD).unwrap())
        );
        assert_eq!(
            fs::metadata(&fixture.store().path)
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }

    #[test]
    fn stale_session_cannot_restore_deleted_or_replaced_credentials() {
        let fixture = Fixture::new();
        let store = fixture.store();
        store.apply(RegistryMessage::Migrate(OLD.into())).unwrap();
        store.apply(RegistryMessage::Set(NEW.into())).unwrap();
        assert_eq!(
            store.apply(RegistryMessage::Migrate(OLD.into())).unwrap(),
            Some(validate(NEW).unwrap())
        );
        store.apply(RegistryMessage::Set("[]".into())).unwrap();
        assert_eq!(
            fixture
                .store()
                .apply(RegistryMessage::Migrate(OLD.into()))
                .unwrap(),
            Some("[]".into())
        );
    }

    #[test]
    fn invalid_update_preserves_last_valid_registry() {
        let fixture = Fixture::new();
        let store = fixture.store();
        store.apply(RegistryMessage::Set(OLD.into())).unwrap();
        for invalid in [
            "not json",
            "{}",
            r#"[{"id":"operator"}]"#,
            r#"[{"id":"","connectionPassword":"secret"}]"#,
        ] {
            assert!(store.apply(RegistryMessage::Set(invalid.into())).is_err());
        }
        assert_eq!(
            store.apply(RegistryMessage::Get).unwrap(),
            Some(validate(OLD).unwrap())
        );
    }

    #[test]
    fn corrupt_authoritative_registry_fails_closed_instead_of_remigrating() {
        let fixture = Fixture::new();
        let store = fixture.store();
        store.apply(RegistryMessage::Set("[]".into())).unwrap();
        fs::write(&store.path, "corrupt").unwrap();
        assert!(store.apply(RegistryMessage::Migrate(OLD.into())).is_err());
        assert!(store.apply(RegistryMessage::Get).is_err());
    }

    #[test]
    fn login_screen_can_read_but_cannot_modify_or_migrate() {
        assert!(RegistryMessage::Get.allowed(false));
        for message in [
            RegistryMessage::Set("[]".into()),
            RegistryMessage::Migrate(OLD.into()),
        ] {
            assert!(!message.allowed(false));
            assert!(message.allowed(true));
        }
        assert!(!RegistryMessage::Value(Some(OLD.into())).allowed(true));
        assert!(!RegistryMessage::Error("test".into()).allowed(true));
    }

    #[test]
    fn oversized_update_is_rejected_without_echoing_credentials() {
        let secret = "private-password".repeat(MAX_REGISTRY_BYTES / 10);
        let error = validate(&secret).unwrap_err().to_string();
        assert_eq!(error, "registration list is too large");
    }
}
