#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct SessionId(pub u64);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct EditorEpoch(pub u64);

/// Opaque resource identity; only storage adapters resolve it to an OS path.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct FileRef(pub u64);
