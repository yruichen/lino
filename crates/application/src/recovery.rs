//! Recovery copies are independent of original-file saves. Restoring creates a
//! new, unsaved document; it never grants permission to overwrite the old file.
use crate::ports::StorageError;
use lino_document::{Snapshot, TextFormat};

#[derive(Clone, Debug)]
pub struct RecoverySnapshot {
    pub snapshot: Snapshot,
    pub format: TextFormat,
    pub label: Option<String>,
}
#[derive(Clone, Debug)]
pub struct RecoveredText {
    pub text: String,
    pub format: TextFormat,
    pub label: Option<String>,
}
#[derive(Clone, Debug)]
pub struct RecoveryEntry {
    pub key: String,
    pub label: Option<String>,
    pub problem: Option<String>,
}
/// Implementations serialize writes/retirement and enforce record/byte limits.
/// The write receipt distinguishes replacement from directory synchronization.
pub trait RecoveryPort: Send {
    fn list(&self) -> Result<Vec<RecoveryEntry>, StorageError>;
    fn read(&self, key: &str) -> Result<RecoveredText, StorageError>;
    fn write(
        &mut self,
        key: Option<&str>,
        value: &RecoverySnapshot,
    ) -> Result<(String, bool), StorageError>;
    fn retire(&mut self, key: &str) -> Result<(), StorageError>;
}
