//! Canonical JSON DTOs. Swift relays them; TypeScript is generated from here.

mod capabilities;
mod documents;
mod envelope;
mod errors;
mod jobs;
mod version;

pub use documents::*;
pub use envelope::*;
pub use errors::*;
pub use version::*;
