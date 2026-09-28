//! Linux registrations belong to the system service, not the current desktop UID.
pub(crate) mod store;
pub use store::RegistryMessage;

use crate::ipc::{self, Data};
use hbb_common::{
    bail,
    config::{Config, LocalConfig},
    log, tokio, ResultType,
};
use std::sync::Mutex;

const LEGACY_KEY: &str = "registered_remote_users";
static SERVICE_REGISTRY_LOCK: Mutex<()> = Mutex::new(());

// Called only by the authenticated _service listener, never the user IPC socket.
pub fn handle_service(message: RegistryMessage, may_write: bool) -> RegistryMessage {
    if !crate::platform::is_root() {
        return RegistryMessage::Error("registration service must run as root".into());
    }
    if !message.allowed(may_write) {
        return RegistryMessage::Error(
            "registrations cannot be changed from the login screen".into(),
        );
    }
    let result = (|| -> ResultType<Option<String>> {
        let _guard = SERVICE_REGISTRY_LOCK
            .lock()
            .map_err(|_| hbb_common::anyhow::anyhow!("registration lock failed"))?;
        let path = Config::path(format!(
            "{}_registered_remote_users.json",
            crate::get_app_name()
        ));
        Ok(store::RegistryStore::new(path).apply(message)?)
    })();
    match result {
        Ok(value) => RegistryMessage::Value(value),
        Err(err) => {
            log::error!("Registered-user service operation failed: {err}");
            RegistryMessage::Error(
                "Could not read or save registered users in the system service".into(),
            )
        }
    }
}

async fn request(message: RegistryMessage) -> ResultType<Option<String>> {
    let mut connection = ipc::connect_service(1000)
        .await
        .map_err(|error| error.context("connect to registration service"))?;
    connection
        .send(&Data::RegisteredRemoteUsers(message))
        .await?;
    match connection
        .next_timeout(3000)
        .await
        .map_err(|error| error.context("read registration service response"))?
    {
        Some(Data::RegisteredRemoteUsers(RegistryMessage::Value(value))) => Ok(value),
        Some(Data::RegisteredRemoteUsers(RegistryMessage::Error(error))) => bail!("{error}"),
        _ => bail!("Registered-user service did not respond; restart the updated MDesk service"),
    }
}

/// Every connection asks the service, so a root/greeter/user server never relies
/// on a stale per-process copy. Password/account checks still run in connection.rs.
pub async fn load() -> ResultType<String> {
    let legacy = LocalConfig::get_option_from_file(LEGACY_KEY);
    // Ordinary authentication is read-only, even if a legacy local copy exists.
    // Only an absent registry needs migration permission; [] remains authoritative.
    let result = async {
        let current = request(RegistryMessage::Get).await?;
        if current.is_none() && !legacy.is_empty() && !crate::platform::is_prelogin() {
            request(RegistryMessage::Migrate(legacy.clone())).await
        } else {
            Ok(current)
        }
    }
    .await;
    match result {
        Ok(value) => Ok(value.unwrap_or_default()),
        Err(error) if !crate::platform::is_installed() && service_absent(&error) => {
            // A standalone application has no system-wide pre-login capability.
            if legacy.is_empty() {
                Ok(legacy)
            } else {
                Ok(store::validate(&legacy)?)
            }
        }
        Err(error) => {
            Err(error.context("Linux registered-user authentication service unavailable"))
        }
    }
}

fn service_absent(error: &hbb_common::anyhow::Error) -> bool {
    error.downcast_ref::<std::io::Error>().is_some_and(|e| {
        matches!(
            e.kind(),
            std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
        )
    })
}

async fn save(json: &str) -> ResultType<String> {
    let json = store::validate(json)?;
    let saved = match request(RegistryMessage::Set(json.clone())).await {
        Ok(Some(saved)) => saved,
        Ok(None) => bail!("Registered-user service did not acknowledge the update"),
        Err(error) if !crate::platform::is_installed() && service_absent(&error) => json,
        Err(error) => {
            return Err(
                error.context("Could not update registered users; check the MDesk system service")
            )
        }
    };
    // Keep a compatible local copy only after the authoritative write succeeds.
    LocalConfig::set_option(LEGACY_KEY.into(), saved.clone());
    Ok(saved)
}

#[tokio::main(flavor = "current_thread")]
pub async fn ui_request(value: Option<&str>) -> String {
    let result = match value {
        Some(value) => save(value).await,
        None => load().await,
    };
    match result {
        Ok(value) => serde_json::json!({"value": value}).to_string(),
        Err(error) => serde_json::json!({"error": error.to_string()}).to_string(),
    }
}
