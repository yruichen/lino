//! Immutable export input; it never owns a second writable document.
use lino_document::{EditorEpoch, SessionId, Snapshot};
#[derive(Clone)]
pub struct ExportSnapshot {
    pub owner: SessionId,
    pub epoch: EditorEpoch,
    pub source: Snapshot,
    pub label: Option<String>,
}
