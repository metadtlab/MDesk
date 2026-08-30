use hbb_common::{
    bail,
    config::{Config, LocalConfig},
    ResultType,
};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default)]
pub struct IssuedConnectionIntent {
    pub source_connection_id: String,
    pub ticket: String,
}

#[derive(Serialize)]
struct ConnectionIntentRequest<'a> {
    target_rid: &'a str,
    source_connection_id: &'a str,
    connection_type: &'a str,
}

#[derive(Deserialize)]
struct ConnectionIntentResponse {
    #[serde(default)]
    ticket: String,
}

/// Requests a short-lived capability from the API using the controller's
/// interactive login. `Ok(None)` deliberately keeps ordinary RustDesk
/// connections working when the user is not signed in or the API is absent;
/// those sessions are not accepted as verified enterprise activity.
pub async fn issue_connection_intent(
    target_rid: &str,
    source_connection_id: &str,
    connection_type: &str,
) -> ResultType<Option<IssuedConnectionIntent>> {
    let access_token = LocalConfig::get_option("access_token");
    if access_token.trim().is_empty() {
        return Ok(None);
    }

    let api_server = crate::common::get_api_server(
        Config::get_option("api-server"),
        Config::get_option("custom-rendezvous-server"),
    );
    if api_server.trim().is_empty() {
        return Ok(None);
    }

    let request = ConnectionIntentRequest {
        target_rid,
        source_connection_id,
        connection_type,
    };
    let body = serde_json::to_string(&request)?;
    let authorization = format!("Authorization: Bearer {}", access_token.trim());
    let response = crate::common::post_request_checked(
        format!(
            "{}/api/connection-intents",
            api_server.trim_end_matches('/')
        ),
        body,
        &authorization,
    )
    .await?;
    let response: ConnectionIntentResponse = serde_json::from_str(&response)?;
    if response.ticket.trim().is_empty() {
        bail!("Connection intent response did not include a ticket");
    }

    Ok(Some(IssuedConnectionIntent {
        source_connection_id: source_connection_id.to_owned(),
        ticket: response.ticket,
    }))
}
