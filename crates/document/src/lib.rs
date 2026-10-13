//! Platform-independent, versioned UTF-8 document values.

mod changes;
mod coordinates;
mod identity;
mod revision;
mod snapshot;
mod text;

pub use changes::{ModelError, TextChange};
pub use coordinates::{utf16_to_utf8, utf8_to_utf16};
pub use identity::{EditorEpoch, FileRef, SessionId};
pub use revision::Revision;
pub use snapshot::Snapshot;
pub use text::{TextFormat, MAX_DOCUMENT_BYTES};
