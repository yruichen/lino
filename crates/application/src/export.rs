//! Immutable export input; it never owns a second writable document.
use lino_document::{SessionId, Snapshot};
#[derive(Clone)]
pub struct ExportSnapshot {
    pub owner: SessionId,
    pub source: Snapshot,
    pub label: Option<String>,
}
