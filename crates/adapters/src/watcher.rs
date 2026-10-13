//! Recursive notifications are invalidations, never authoritative file state.
use lino_application::ports::StorageError;
use notify::{RecursiveMode, Watcher};
use std::{
    path::Path,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
};

pub struct DirectoryWatch {
    _watcher: notify::RecommendedWatcher,
    dirty: Arc<AtomicBool>,
}
pub struct FileWatch {
    _watcher: notify::RecommendedWatcher,
}
impl FileWatch {
    pub fn new(file: &Path, changed: Arc<dyn Fn() + Send + Sync>) -> Result<Self, StorageError> {
        let path = file.to_owned();
        let parent = file.parent().ok_or(StorageError::Denied)?;
        let mut watcher =
            notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
                if event
                    .as_ref()
                    .map(|event| {
                        !matches!(event.kind, notify::EventKind::Access(_))
                            && (event.paths.is_empty() || event.paths.contains(&path))
                    })
                    .unwrap_or(true)
                {
                    changed();
                }
            })
            .map_err(|error| StorageError::Io(error.to_string()))?;
        watcher
            .watch(parent, RecursiveMode::NonRecursive)
            .map_err(|error| StorageError::Io(error.to_string()))?;
        Ok(Self { _watcher: watcher })
    }
}
impl DirectoryWatch {
    pub fn new(root: &Path, changed: Arc<dyn Fn() + Send + Sync>) -> Result<Self, StorageError> {
        let dirty = Arc::new(AtomicBool::new(false));
        let signal = dirty.clone();
        let mut watcher =
            notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
                // Errors and overflow also invalidate the listing. Access events do
                // not trigger a rescan loop caused by our own directory reads.
                if event
                    .as_ref()
                    .map(|e| !matches!(e.kind, notify::EventKind::Access(_)))
                    .unwrap_or(true)
                    && !signal.swap(true, Ordering::AcqRel)
                {
                    changed();
                }
            })
            .map_err(|e| StorageError::Io(e.to_string()))?;
        watcher
            .watch(root, RecursiveMode::Recursive)
            .map_err(|e| StorageError::Io(e.to_string()))?;
        Ok(Self {
            _watcher: watcher,
            dirty,
        })
    }
    pub fn acknowledge(&self) {
        self.dirty.store(false, Ordering::Release);
    }
}
