//! Immutable source-ranged Markdown nodes. Nodes never own writable document text.

use std::ops::Range;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum NodeKind {
    Heading { level: u8 },
    Paragraph,
    CodeFence { marker: char },
    ThematicBreak,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Node {
    pub kind: NodeKind,
    pub range: Range<usize>,
    pub content: Range<usize>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Document {
    pub nodes: Vec<Node>,
    pub source_len: usize,
}
