use crate::{
    dispatch::{error, storage_error},
    DocumentRuntime,
};
use lino_adapters::workspace::{FileWorkspace, Matcher};
pub use lino_application::workspace::{Entry, Listing, Mutation, SearchOptions, SearchResult};
use lino_application::{ports::StorageError, workspace::Workspace};
use lino_protocol::{ErrorCode, WireError};
use std::{
    path::Path,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
};

pub struct WorkspaceRuntime {
    files: Arc<FileWorkspace>,
    workspace: Workspace,
    query: Mutex<QueryState>,
    watcher: Mutex<Option<lino_adapters::watcher::DirectoryWatch>>,
}
#[derive(Default)]
struct QueryState {
    last_id: u64,
    cancelled_through: u64,
    active: Option<(u64, Arc<AtomicBool>)>,
}
impl WorkspaceRuntime {
    pub fn open(path: &Path) -> Result<Self, WireError> {
        let files = Arc::new(FileWorkspace::open(path).map_err(storage_error)?);
        Ok(Self {
            workspace: Workspace::new(files.clone()),
            files,
            query: Mutex::default(),
            watcher: Mutex::default(),
        })
    }
    pub fn root(&self) -> String {
        self.files.root().to_string_lossy().into_owned()
    }
    pub fn watch(&self, changed: Arc<dyn Fn() + Send + Sync>) -> Result<(), WireError> {
        let watcher = lino_adapters::watcher::DirectoryWatch::new(self.files.root(), changed)
            .map_err(storage_error)?;
        let previous = self
            .watcher
            .lock()
            .map_err(|_| error(ErrorCode::Internal, "Watcher lock poisoned", false))?
            .replace(watcher);
        drop(previous);
        Ok(())
    }
    pub fn unwatch(&self) {
        let previous = self
            .watcher
            .lock()
            .ok()
            .and_then(|mut watcher| watcher.take());
        drop(previous);
    }
    pub fn list(&self, path: &str, hidden: bool) -> Result<Listing, WireError> {
        self.acknowledge_changes();
        self.workspace.list(path, hidden).map_err(storage_error)
    }
    pub fn path(&self, relative: &str) -> Result<String, WireError> {
        Ok(self
            .files
            .resolve(relative, false)
            .map_err(storage_error)?
            .to_string_lossy()
            .into_owned())
    }
    pub fn cancel(&self, id: u64) {
        if let Ok(mut query) = self.query.lock() {
            query.cancelled_through = query.cancelled_through.max(id);
            if query
                .active
                .as_ref()
                .is_some_and(|(current, _)| *current <= id)
            {
                if let Some((_, token)) = query.active.take() {
                    token.store(true, Ordering::Relaxed);
                }
            }
        }
    }
    pub fn search(&self, id: u64, options: SearchOptions) -> Result<SearchResult, WireError> {
        self.acknowledge_changes();
        let token = Arc::new(AtomicBool::new(false));
        {
            let mut query = self
                .query
                .lock()
                .map_err(|_| error(ErrorCode::Internal, "Query lock poisoned", false))?;
            if id <= query.last_id || id <= query.cancelled_through {
                return Ok(SearchResult {
                    hits: Vec::new(),
                    truncated: false,
                    skipped: 0,
                    cancelled: true,
                });
            }
            query.last_id = id;
            if let Some((_, previous)) = query.active.replace((id, token.clone())) {
                previous.store(true, Ordering::Relaxed);
            }
        }
        let result = Matcher::compile(&options)
            .map_err(storage_error)
            .and_then(|matcher| {
                self.workspace
                    .search(&options, &matcher, &token)
                    .map_err(storage_error)
            });
        if let Ok(mut query) = self.query.lock() {
            if query
                .active
                .as_ref()
                .is_some_and(|(current, _)| *current == id)
            {
                query.active.take();
            }
        }
        result
    }
    fn acknowledge_changes(&self) {
        if let Ok(watcher) = self.watcher.lock() {
            if let Some(watcher) = watcher.as_ref() {
                watcher.acknowledge();
            }
        }
    }
    pub fn mutate(
        &self,
        docs: &DocumentRuntime,
        operation: Mutation,
        source: &str,
        target: &str,
    ) -> Result<(), WireError> {
        let from = if source.is_empty() {
            None
        } else {
            Some(self.files.resolve(source, false).map_err(storage_error)?)
        };
        // Keep file registration and mutation mutually exclusive. File operations
        // are bounded; no UI thread executes this method.
        let _gate = docs
            .file_gate
            .lock()
            .map_err(|_| error(ErrorCode::Internal, "File gate poisoned", false))?;
        self.require_unused(
            docs,
            &self.files.resolve(target, true).map_err(storage_error)?,
        )?;
        if matches!(operation, Mutation::Move) {
            if let Some(path) = &from {
                self.require_unused(docs, path)?;
            }
        }
        self.workspace
            .mutate(operation, source, target)
            .map_err(storage_error)
    }
    pub fn trash(&self, docs: &DocumentRuntime, relative: &str) -> Result<(), WireError> {
        if relative.is_empty() {
            return Err(storage_error(StorageError::Denied));
        }
        let path = self.files.resolve(relative, false).map_err(storage_error)?;
        let _gate = docs
            .file_gate
            .lock()
            .map_err(|_| error(ErrorCode::Internal, "File gate poisoned", false))?;
        self.require_unused(docs, &path)?;
        lino_adapters::workspace::trash_path(&path).map_err(storage_error)
    }
    fn require_unused(&self, docs: &DocumentRuntime, path: &Path) -> Result<(), WireError> {
        if docs
            .resources
            .is_registered_below(path)
            .map_err(storage_error)?
        {
            return Err(error(
                ErrorCode::Busy,
                "Close documents inside the selected path before moving or deleting it.",
                false,
            ));
        }
        Ok(())
    }
}
