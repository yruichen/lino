//! Immutable, source-ranged Markdown analysis with no I/O or editor state.

mod analysis;
mod ast;
mod dialect;
mod parse;
mod source_map;

pub use analysis::{analyze, headings, Heading};
pub use ast::{Document, Node, NodeKind};
pub use dialect::Dialect;
pub use parse::parse;
pub use source_map::SourceMap;
