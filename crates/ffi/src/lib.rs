//! Generated Swift facade. Business rules remain in the shared runtime.

mod conversion;
mod exports;
mod handles;

pub use exports::{BridgeError, DocumentService};
uniffi::setup_scaffolding!();
