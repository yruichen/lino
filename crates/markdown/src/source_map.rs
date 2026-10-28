//! Byte offsets and line boundaries for source-ranged analysis.

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SourceMap {
    starts: Vec<usize>,
    source_len: usize,
}
impl SourceMap {
    pub fn new(source: &str) -> Self {
        let mut starts = vec![0];
        for (offset, character) in source.char_indices() {
            if character == '\n' {
                starts.push(offset + 1);
            }
        }
        Self {
            starts,
            source_len: source.len(),
        }
    }
    pub fn line_count(&self) -> usize {
        self.starts.len()
    }
    pub fn line_start(&self, line: usize) -> Option<usize> {
        self.starts.get(line).copied()
    }
    pub fn line_at(&self, offset: usize) -> Option<usize> {
        if offset > self.source_len {
            return None;
        }
        match self.starts.binary_search(&offset) {
            Ok(line) => Some(line),
            Err(next) => next.checked_sub(1),
        }
    }
}
