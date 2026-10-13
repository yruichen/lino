//! Workspace queries operate on granted roots and relative paths, never UI state.
use crate::ports::StorageError;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};

#[derive(Clone, Debug)]
pub struct Entry {
    pub path: String,
    pub name: String,
    pub directory: bool,
    pub bytes: u64,
    pub modified: u64,
}
#[derive(Clone, Debug)]
pub struct Listing {
    pub entries: Vec<Entry>,
    pub truncated: bool,
}
#[derive(Clone, Debug)]
pub struct Hit {
    pub path: String,
    pub line: u64,
    pub preview: String,
}
#[derive(Clone, Debug)]
pub struct SearchResult {
    pub hits: Vec<Hit>,
    pub truncated: bool,
    pub skipped: u64,
    pub cancelled: bool,
}
#[derive(Clone, Debug)]
pub enum Mutation {
    NewFile,
    NewDirectory,
    Copy,
    Move,
}
#[derive(Clone, Debug)]
pub struct SearchOptions {
    pub text: String,
    pub content: bool,
    pub case_sensitive: bool,
    pub regex: bool,
    pub whole_word: bool,
    pub include_hidden: bool,
}

pub trait WorkspacePort: Send + Sync {
    fn list(&self, path: &str, include_hidden: bool) -> Result<Listing, StorageError>;
    fn read(&self, path: &str) -> Result<String, StorageError>;
    fn mutate(&self, operation: Mutation, source: &str, target: &str) -> Result<(), StorageError>;
}
pub trait SearchMatcher: Send + Sync {
    fn matches(&self, text: &str) -> bool;
}

pub struct Workspace {
    port: Arc<dyn WorkspacePort>,
}
impl Workspace {
    pub fn new(port: Arc<dyn WorkspacePort>) -> Self {
        Self { port }
    }
    pub fn list(&self, path: &str, hidden: bool) -> Result<Listing, StorageError> {
        self.port.list(path, hidden)
    }
    pub fn mutate(
        &self,
        operation: Mutation,
        source: &str,
        target: &str,
    ) -> Result<(), StorageError> {
        self.port.mutate(operation, source, target)
    }
    pub fn search(
        &self,
        options: &SearchOptions,
        matcher: &dyn SearchMatcher,
        cancelled: &AtomicBool,
    ) -> Result<SearchResult, StorageError> {
        let mut result = SearchResult {
            hits: Vec::new(),
            truncated: false,
            skipped: 0,
            cancelled: false,
        };
        let mut pending = vec![(String::new(), 0)];
        let mut visited = 0usize;
        let mut read_bytes = 0usize;
        while let Some((directory, depth)) = pending.pop() {
            if cancelled.load(Ordering::Relaxed) {
                result.cancelled = true;
                break;
            }
            let listing = match self.port.list(&directory, options.include_hidden) {
                Ok(listing) => listing,
                Err(_) if !directory.is_empty() => {
                    result.skipped += 1;
                    continue;
                }
                Err(error) => return Err(error),
            };
            result.truncated |= listing.truncated;
            for entry in listing.entries {
                if cancelled.load(Ordering::Relaxed) {
                    result.cancelled = true;
                    return Ok(result);
                }
                visited += 1;
                if visited > 50_000 || result.hits.len() >= 1000 {
                    result.truncated = true;
                    return Ok(result);
                }
                if entry.directory {
                    if depth < 64 {
                        pending.push((entry.path, depth + 1));
                    } else {
                        result.truncated = true;
                    }
                    continue;
                }
                if !options.content {
                    if matcher.matches(&entry.path) {
                        result.hits.push(Hit {
                            path: entry.path,
                            line: 1,
                            preview: String::new(),
                        });
                    }
                    continue;
                }
                if entry.bytes > 4 * 1024 * 1024 {
                    result.skipped += 1;
                    continue;
                }
                read_bytes += entry.bytes as usize;
                if read_bytes > 128 * 1024 * 1024 {
                    result.truncated = true;
                    return Ok(result);
                }
                let text = match self.port.read(&entry.path) {
                    Ok(text) => text,
                    Err(_) => {
                        result.skipped += 1;
                        continue;
                    }
                };
                for (n, line) in text.lines().enumerate() {
                    if cancelled.load(Ordering::Relaxed) {
                        result.cancelled = true;
                        return Ok(result);
                    }
                    if matcher.matches(line) {
                        result.hits.push(Hit {
                            path: entry.path.clone(),
                            line: n as u64 + 1,
                            preview: line.chars().take(180).collect(),
                        });
                        if result.hits.len() >= 1000 {
                            result.truncated = true;
                            return Ok(result);
                        }
                    }
                }
            }
        }
        Ok(result)
    }
}
