use crate::{ApplyAck, DocumentStatus, SaveReceipt, SaveTarget, SaveTicket, WireChange, WireError};
use serde::{Deserialize, Serialize};
use ts_rs::TS;

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Request {
    Handshake {
        resource_version: String,
    },
    ApplyChanges {
        session_id: String,
        epoch: String,
        sequence: String,
        base_revision: String,
        changes: Vec<WireChange>,
    },
    PrepareSave {
        session_id: String,
        epoch: String,
        revision: String,
        target: Option<SaveTarget>,
    },
    CommitSave {
        session_id: String,
        epoch: String,
        ticket_id: String,
    },
    AbortSave {
        session_id: String,
        epoch: String,
        ticket_id: String,
    },
    Checkpoint {
        session_id: String,
        epoch: String,
    },
    Status {
        session_id: String,
    },
    Close {
        session_id: String,
        epoch: String,
        revision: String,
        discard: bool,
    },
    #[serde(other)]
    UnsupportedOperation,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(deny_unknown_fields)]
pub struct RequestEnvelope {
    pub protocol_version: u32,
    pub request_id: String,
    pub operation: Request,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Response {
    Handshake {
        resource_version: String,
        capabilities: Vec<String>,
    },
    Applied {
        ack: ApplyAck,
        status: DocumentStatus,
    },
    Prepared {
        ticket: SaveTicket,
    },
    Saved {
        receipt: SaveReceipt,
        status: DocumentStatus,
    },
    Status {
        status: DocumentStatus,
    },
    Checkpointed {
        revision: String,
        durable: bool,
    },
    Closed,
    Aborted,
    Error {
        error: WireError,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
pub struct ResponseEnvelope {
    pub protocol_version: u32,
    pub request_id: String,
    pub result: Response,
}
