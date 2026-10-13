//! Generated Swift facade. Business rules remain in the shared runtime.

mod assets;
mod conversion;
mod export;
mod exports;
mod external;
mod handles;
mod preferences;

pub use exports::{BridgeError, DocumentService};
uniffi::setup_scaffolding!();

mod workspace;
