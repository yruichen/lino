use open_typora_document::{FileRef, Snapshot, TextFormat};
use std::fmt;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DiskVersion(pub String);

#[derive(Clone, Debug)]
pub struct LoadedFile {
    pub text: String,
    pub format: TextFormat,
    pub version: DiskVersion,
    pub label: String,
}

#[derive(Clone, Debug)]
pub struct StorageCommit {
    pub target: FileRef,
    /// None means the target must still be absent.
    pub expected: Option<DiskVersion>,
    pub snapshot: Snapshot,
    pub format: TextFormat,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum StorageError {
    NotFound,
    Denied,
    ChangedExternally,
    UnsupportedEncoding,
    UnsupportedFile,
    LimitExceeded,
    Io(String),
}
impl fmt::Display for StorageError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for StorageError {}

pub trait StoragePort: Send + Sync {
    fn load(&self, file: FileRef) -> Result<LoadedFile, StorageError>;
    fn inspect(&self, file: FileRef) -> Result<Option<DiskVersion>, StorageError>;
    /// The boolean reports whether file AND directory synchronization succeeded.
    fn commit(&self, request: &StorageCommit) -> Result<(DiskVersion, bool), StorageError>;
}
