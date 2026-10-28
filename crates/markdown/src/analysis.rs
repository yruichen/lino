//! Pure semantic projections over the source-ranged Markdown tree.

use crate::{
    ast::{Document, NodeKind},
    dialect::Dialect,
    parse::parse,
};
use std::ops::Range;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Heading {
    pub level: u8,
    pub range: Range<usize>,
    pub content: Range<usize>,
}

pub fn headings(source: &str, dialect: Dialect) -> Vec<Heading> {
    parse(source, dialect)
        .nodes
        .into_iter()
        .filter_map(|node| match node.kind {
            NodeKind::Heading { level } => Some(Heading {
                level,
                range: node.range,
                content: node.content,
            }),
            _ => None,
        })
        .collect()
}

pub fn analyze(source: &str, dialect: Dialect) -> Document {
    parse(source, dialect)
}
