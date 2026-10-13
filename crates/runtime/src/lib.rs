//! Shared document service composition and protocol dispatch.

mod composition;
mod dispatch;
mod events;
mod recovery;
mod scheduler;
mod sessions;
mod shutdown;

pub use composition::DocumentRuntime;
