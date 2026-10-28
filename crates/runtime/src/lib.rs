//! Shared document service composition and protocol dispatch.

mod assets;
mod compile;
mod composition;
mod dispatch;
mod events;
pub mod export;
mod external;
mod preferences;
mod recovery;
mod scheduler;
mod sessions;
mod shutdown;
mod updates;

pub use compile::CompileJob;
pub use composition::DocumentRuntime;
pub use external::DocumentWatch;

pub mod workspace;

pub mod navigation;
