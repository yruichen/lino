//! Typed native workspace facade; filesystem and query rules stay in Rust.
use crate::exports::{wire_error, BridgeError, DocumentService};
use lino_runtime::{
    workspace::{Mutation, SearchOptions, WorkspaceRuntime},
    DocumentRuntime,
};
use std::{path::Path, sync::Arc};
#[derive(uniffi::Record)]
pub struct WorkspaceEntry {
    pub path: String,
    pub name: String,
    pub directory: bool,
    pub bytes: u64,
    pub modified: u64,
}
#[derive(uniffi::Record)]
pub struct WorkspaceListing {
    pub entries: Vec<WorkspaceEntry>,
    pub truncated: bool,
}
#[derive(uniffi::Record)]
pub struct WorkspaceHit {
    pub path: String,
    pub line: u64,
    pub preview: String,
}
#[derive(uniffi::Record)]
pub struct WorkspaceSearch {
    pub hits: Vec<WorkspaceHit>,
    pub truncated: bool,
    pub skipped: u64,
    pub cancelled: bool,
}
#[derive(uniffi::Enum)]
pub enum WorkspaceMutation {
    NewFile,
    NewDirectory,
    Copy,
    Move,
}
#[derive(uniffi::Record)]
pub struct WorkspaceSearchOptions {
    pub text: String,
    pub content: bool,
    pub case_sensitive: bool,
    pub regex: bool,
    pub whole_word: bool,
    pub include_hidden: bool,
}
#[derive(uniffi::Object)]
pub struct WorkspaceService {
    workspace: WorkspaceRuntime,
    documents: Arc<DocumentRuntime>,
}
#[uniffi::export(callback_interface)]
pub trait WorkspaceListener: Send + Sync {
    fn changed(&self);
}
#[uniffi::export]
impl DocumentService {
    pub fn open_workspace(&self, path: String) -> Result<Arc<WorkspaceService>, BridgeError> {
        Ok(Arc::new(WorkspaceService {
            workspace: WorkspaceRuntime::open(Path::new(&path)).map_err(wire_error)?,
            documents: self.runtime.clone(),
        }))
    }
    pub fn document_path(&self, session_id: String) -> Result<Option<String>, BridgeError> {
        self.runtime.document_path(&session_id).map_err(wire_error)
    }
    pub fn file_session(&self, path: String) -> Result<Option<String>, BridgeError> {
        self.runtime
            .file_session(Path::new(&path))
            .map_err(wire_error)
    }
}
#[uniffi::export]
impl WorkspaceService {
    pub fn watch(&self, listener: Box<dyn WorkspaceListener>) -> Result<(), BridgeError> {
        self.workspace
            .watch(Arc::new(move || listener.changed()))
            .map_err(wire_error)
    }
    pub fn unwatch(&self) {
        self.workspace.unwatch();
    }
    pub fn root(&self) -> String {
        self.workspace.root()
    }
    pub fn resolve(&self, path: String) -> Result<String, BridgeError> {
        self.workspace.path(&path).map_err(wire_error)
    }
    pub fn list(&self, path: String, hidden: bool) -> Result<WorkspaceListing, BridgeError> {
        let result = self.workspace.list(&path, hidden).map_err(wire_error)?;
        Ok(WorkspaceListing {
            entries: result
                .entries
                .into_iter()
                .map(|e| WorkspaceEntry {
                    path: e.path,
                    name: e.name,
                    directory: e.directory,
                    bytes: e.bytes,
                    modified: e.modified,
                })
                .collect(),
            truncated: result.truncated,
        })
    }
    pub fn search(
        &self,
        query_id: u64,
        options: WorkspaceSearchOptions,
    ) -> Result<WorkspaceSearch, BridgeError> {
        let result = self
            .workspace
            .search(
                query_id,
                SearchOptions {
                    text: options.text,
                    content: options.content,
                    case_sensitive: options.case_sensitive,
                    regex: options.regex,
                    whole_word: options.whole_word,
                    include_hidden: options.include_hidden,
                },
            )
            .map_err(wire_error)?;
        Ok(WorkspaceSearch {
            hits: result
                .hits
                .into_iter()
                .map(|h| WorkspaceHit {
                    path: h.path,
                    line: h.line,
                    preview: h.preview,
                })
                .collect(),
            truncated: result.truncated,
            skipped: result.skipped,
            cancelled: result.cancelled,
        })
    }
    pub fn cancel(&self, query_id: u64) {
        self.workspace.cancel(query_id);
    }
    pub fn mutate(
        &self,
        operation: WorkspaceMutation,
        source: String,
        target: String,
    ) -> Result<(), BridgeError> {
        let operation = match operation {
            WorkspaceMutation::NewFile => Mutation::NewFile,
            WorkspaceMutation::NewDirectory => Mutation::NewDirectory,
            WorkspaceMutation::Copy => Mutation::Copy,
            WorkspaceMutation::Move => Mutation::Move,
        };
        self.workspace
            .mutate(&self.documents, operation, &source, &target)
            .map_err(wire_error)
    }
    pub fn trash(&self, path: String) -> Result<(), BridgeError> {
        self.workspace
            .trash(&self.documents, &path)
            .map_err(wire_error)
    }
}
