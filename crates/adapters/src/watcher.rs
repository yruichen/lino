//! Recursive notifications are invalidations, never authoritative file state.
use lino_application::ports::StorageError;
use notify::{RecursiveMode, Watcher};
use std::{
    path::Path,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};

pub struct DirectoryWatch {
    _watcher: notify::RecommendedWatcher,
    dirty: Arc<AtomicBool>,
    alive: Arc<AtomicBool>,
}
pub struct FileWatch {
    _watcher: notify::RecommendedWatcher,
    alive: Arc<AtomicBool>,
}
impl FileWatch {
    pub fn new(file: &Path, changed: Arc<dyn Fn() + Send + Sync>) -> Result<Self, StorageError> {
        let path = file.to_owned();
        let parent = file.parent().ok_or(StorageError::Denied)?;
        let last_notification = Arc::new(Mutex::new(None::<Instant>));
        let throttle = last_notification.clone();
        let alive = Arc::new(AtomicBool::new(true));
        let callback_alive = alive.clone();
        let mut watcher =
            notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
                let relevant = event
                    .as_ref()
                    .map(|event| {
                        !matches!(event.kind, notify::EventKind::Access(_))
                            && (event.paths.is_empty() || event.paths.contains(&path))
                    })
                    .unwrap_or(true);
                if !relevant || !callback_alive.load(Ordering::Acquire) {
                    return;
                }
                let now = Instant::now();
                let should_notify = throttle
                    .lock()
                    .map(|mut last| {
                        let notify = last
                            .map(|value| now.duration_since(value) >= Duration::from_millis(100))
                            .unwrap_or(true);
                        if notify {
                            *last = Some(now);
                        }
                        notify
                    })
                    .unwrap_or(true);
                if should_notify {
                    changed();
                }
            })
            .map_err(|error| StorageError::Io(error.to_string()))?;
        watcher
            .watch(parent, RecursiveMode::NonRecursive)
            .map_err(|error| StorageError::Io(error.to_string()))?;
        Ok(Self {
            _watcher: watcher,
            alive,
        })
    }
}
impl Drop for FileWatch {
    fn drop(&mut self) {
        self.alive.store(false, Ordering::Release);
    }
}
impl DirectoryWatch {
    pub fn new(root: &Path, changed: Arc<dyn Fn() + Send + Sync>) -> Result<Self, StorageError> {
        let dirty = Arc::new(AtomicBool::new(false));
        let signal = dirty.clone();
        let alive = Arc::new(AtomicBool::new(true));
        let callback_alive = alive.clone();
        let mut watcher =
            notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
                // Errors and overflow also invalidate the listing. Access events do
                // not trigger a rescan loop caused by our own directory reads.
                if event
                    .as_ref()
                    .map(|e| !matches!(e.kind, notify::EventKind::Access(_)))
                    .unwrap_or(true)
                    && callback_alive.load(Ordering::Acquire)
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
            alive,
        })
    }
    pub fn acknowledge(&self) {
        self.dirty.store(false, Ordering::Release);
    }
}
impl Drop for DirectoryWatch {
    fn drop(&mut self) {
        self.alive.store(false, Ordering::Release);
    }
}
