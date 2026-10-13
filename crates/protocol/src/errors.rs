use serde::{Deserialize, Serialize};
use ts_rs::TS;

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize, TS)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    UnknownSession,
    OldEpoch,
    SequenceGap,
    StaleRevision,
    DuplicateMismatch,
    InvalidChange,
    Busy,
    NotSaved,
    InvalidTicket,
    ResourceLimit,
    NotFound,
    Denied,
    ChangedExternally,
    UnsupportedEncoding,
    UnsupportedFile,
    TooLarge,
    Io,
    ProtocolMismatch,
    InvalidMessage,
    UnsupportedOperation,
    Internal,
}

#[derive(Clone, Debug, Eq, PartialEq, Deserialize, Serialize, TS)]
#[serde(deny_unknown_fields)]
pub struct WireError {
    pub code: ErrorCode,
    pub retryable: bool,
    pub message: String,
}
