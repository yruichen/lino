use serde::{Deserialize, Serialize};
use ts_rs::TS;

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(deny_unknown_fields)]
pub struct WireChange {
    pub from: u32,
    pub to: u32,
    pub insert: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(deny_unknown_fields)]
pub struct SaveTarget {
    pub file_ref: String,
    pub expected_version: Option<String>,
    pub label: String,
    /// Optional v1 extension. Distinguishes independently held native targets.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub reservation_id: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(deny_unknown_fields)]
pub struct CloseIntent {
    pub session_id: String,
    pub epoch: String,
    pub revision: String,
    pub discard: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(deny_unknown_fields)]
pub struct DocumentStatus {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub read_only: Option<bool>,
    pub session_id: String,
    pub epoch: String,
    pub revision: String,
    pub saved_revision: Option<String>,
    pub file_ref: Option<String>,
    pub label: Option<String>,
    pub dirty: bool,
    pub saving: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(deny_unknown_fields)]
pub struct OpenedDocument {
    pub protocol_version: u32,
    pub resource_version: String,
    pub status: DocumentStatus,
    pub text: String,
    pub utf8_bom: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
pub struct ApplyAck {
    pub sequence: String,
    pub revision: String,
    /// Acceptance alone does not acknowledge recovery persistence.
    pub recovery_durable: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
pub struct SaveTicket {
    pub ticket_id: String,
    pub revision: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
pub struct SaveReceipt {
    pub ticket_id: String,
    pub revision: String,
    pub durable: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
pub struct RecoveryEntry {
    pub key: String,
    pub label: Option<String>,
    pub problem: Option<String>,
}
