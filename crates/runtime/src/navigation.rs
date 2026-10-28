//! Shared personal navigation, persisted separately from editor preferences.
use crate::{
    dispatch::{error, storage_error},
    DocumentRuntime,
};
use lino_adapters::{
    settings::FileSettings,
    workspace::{navigation_path, FileWorkspace},
};
use lino_application::{
    navigation::{file_score, supported_browsing_extension, NavigationPreferences},
    workspace::WorkspacePort,
};
use lino_protocol::{ErrorCode, WireError};
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
};

// Serialization belongs to the runtime boundary; the application model remains pure.
#[derive(Serialize, Deserialize)]
#[serde(remote = "NavigationPreferences")]
struct NavigationPreferencesWire {
    locations: Vec<String>,
    favorites: Vec<String>,
    sections: Vec<String>,
    show_favorites: bool,
    show_locations: bool,
    show_open_files: bool,
    show_recents: bool,
    follow_active: bool,
    show_root: bool,
    show_extensions: bool,
    compact: bool,
    sort: String,
}
pub fn parse_navigation_values(json: &str) -> Result<NavigationPreferences, serde_json::Error> {
    let mut deserializer = serde_json::Deserializer::from_str(json);
    let value = NavigationPreferencesWire::deserialize(&mut deserializer)?;
    deserializer.end()?;
    Ok(value)
}
#[derive(Clone, Serialize, Deserialize)]
pub struct NavigationSnapshot {
    pub schema_version: u32,
    pub revision: u64,
    #[serde(with = "NavigationPreferencesWire")]
    pub values: NavigationPreferences,
    pub recent: Vec<String>,
    pub storage_warning: bool,
}
impl Default for NavigationSnapshot {
    fn default() -> Self {
        Self {
            schema_version: 1,
            revision: 0,
            values: NavigationPreferences::default(),
            recent: vec![],
            storage_warning: false,
        }
    }
}
#[derive(Clone, Serialize)]
pub struct QuickFile {
    pub path: String,
    pub name: String,
    pub title: String,
    pub location: String,
}
#[derive(Clone, Serialize, Default)]
pub struct QuickResults {
    pub files: Vec<QuickFile>,
    pub truncated: bool,
    pub skipped: u64,
    pub cancelled: bool,
}
#[derive(Default)]
pub(crate) struct NavigationRuntime {
    snapshot: NavigationSnapshot,
    store: Option<FileSettings>,
    indexes: HashMap<String, (u64, Arc<QuickResults>)>,
    epoch: u64,
}
fn invalid(message: impl AsRef<str>) -> WireError {
    error(ErrorCode::InvalidMessage, message.as_ref(), false)
}
fn io(e: std::io::Error) -> WireError {
    error(ErrorCode::Io, &e.to_string(), true)
}
fn validate(snapshot: &NavigationSnapshot) -> Result<(), WireError> {
    if snapshot.schema_version != 1 {
        return Err(invalid(
            "Unsupported navigation schema; original file retained",
        ));
    }
    snapshot.values.validate().map_err(invalid)?;
    if snapshot.recent.len() > 64
        || snapshot
            .values
            .locations
            .iter()
            .chain(&snapshot.values.favorites)
            .chain(&snapshot.recent)
            .any(|p| !Path::new(p).is_absolute())
    {
        return Err(invalid("Invalid navigation paths"));
    }
    Ok(())
}
fn persist(
    runtime: &mut NavigationRuntime,
    mut next: NavigationSnapshot,
) -> Result<NavigationSnapshot, WireError> {
    validate(&next)?;
    next.revision = runtime
        .snapshot
        .revision
        .checked_add(1)
        .ok_or_else(|| invalid("Navigation revision exhausted"))?;
    let bytes = serde_json::to_vec_pretty(&next).map_err(|e| invalid(e.to_string()))?;
    let store = runtime
        .store
        .as_ref()
        .ok_or_else(|| invalid("Navigation storage is not configured"))?;
    next.storage_warning = !store.save(&bytes).map_err(io)?;
    runtime.snapshot = next.clone();
    Ok(next)
}
impl DocumentRuntime {
    pub fn configure_navigation(
        &self,
        path: &Path,
        legacy_locations: Vec<String>,
    ) -> Result<NavigationSnapshot, WireError> {
        let mut runtime = self
            .navigation
            .lock()
            .map_err(|_| invalid("Navigation lock poisoned"))?;
        if runtime.store.is_some() {
            return Ok(runtime.snapshot.clone());
        }
        let store = FileSettings::new(path);
        let snapshot = if let Some(bytes) = store.load().map_err(io)? {
            let mut snapshot: NavigationSnapshot =
                serde_json::from_slice(&bytes).map_err(|e| invalid(e.to_string()))?;
            validate(&snapshot)?;
            snapshot.storage_warning = false;
            snapshot
        } else {
            let mut snapshot = NavigationSnapshot::default();
            for location in legacy_locations {
                if let Ok(files) = FileWorkspace::open(Path::new(&location)) {
                    let path = files.root().to_string_lossy().into_owned();
                    if !snapshot.values.locations.contains(&path)
                        && snapshot.values.locations.len() < 32
                    {
                        snapshot.values.locations.push(path);
                    }
                }
            }
            snapshot.storage_warning = !store
                .save(&serde_json::to_vec_pretty(&snapshot).map_err(|e| invalid(e.to_string()))?)
                .map_err(io)?;
            snapshot
        };
        runtime.snapshot = snapshot.clone();
        runtime.store = Some(store);
        Ok(snapshot)
    }
    pub fn navigation(&self) -> Result<NavigationSnapshot, WireError> {
        Ok(self
            .navigation
            .lock()
            .map_err(|_| invalid("Navigation lock poisoned"))?
            .snapshot
            .clone())
    }
    pub fn update_navigation(
        &self,
        revision: u64,
        mut values: NavigationPreferences,
    ) -> Result<NavigationSnapshot, WireError> {
        let mut runtime = self
            .navigation
            .lock()
            .map_err(|_| invalid("Navigation lock poisoned"))?;
        if runtime.snapshot.revision != revision {
            return Err(error(
                ErrorCode::StaleRevision,
                "Navigation changed; reload before updating",
                true,
            ));
        }
        for paths in [&mut values.locations, &mut values.favorites] {
            for path in paths.iter_mut() {
                match navigation_path(Path::new(path)) {
                    Ok(canonical) => *path = canonical.to_string_lossy().into_owned(),
                    Err(lino_application::ports::StorageError::NotFound) => {}
                    Err(e) => return Err(storage_error(e)),
                }
            }
            let mut seen = HashSet::new();
            paths.retain(|path| seen.insert(path.clone()));
        }
        let mut next = runtime.snapshot.clone();
        next.values = values;
        let result = persist(&mut runtime, next)?;
        runtime
            .indexes
            .retain(|root, _| result.values.locations.contains(root));
        Ok(result)
    }
    pub fn note_navigation_file(&self, path: &Path) -> Result<NavigationSnapshot, WireError> {
        let path = navigation_path(path)
            .map_err(storage_error)?
            .to_string_lossy()
            .into_owned();
        let mut runtime = self
            .navigation
            .lock()
            .map_err(|_| invalid("Navigation lock poisoned"))?;
        if runtime.snapshot.recent.first() == Some(&path) {
            return Ok(runtime.snapshot.clone());
        }
        let mut next = runtime.snapshot.clone();
        next.recent.retain(|p| p != &path);
        next.recent.insert(0, path);
        next.recent.truncate(64);
        persist(&mut runtime, next)
    }
    pub fn invalidate_navigation(&self) {
        if let Ok(mut runtime) = self.navigation.lock() {
            runtime.epoch = runtime.epoch.wrapping_add(1);
            runtime.indexes.clear();
        }
    }
    pub fn quick_files(
        &self,
        query: &str,
        scope: Option<&Path>,
        current: Option<&str>,
        cancelled: &AtomicBool,
    ) -> Result<QuickResults, WireError> {
        if query.len() > 4096 {
            return Err(invalid("Search query is too long"));
        }
        if cancelled.load(Ordering::Relaxed) {
            return Ok(QuickResults {
                cancelled: true,
                ..Default::default()
            });
        }
        let snapshot = self.navigation()?;
        let start_epoch = self
            .navigation
            .lock()
            .map_err(|_| invalid("Navigation lock poisoned"))?
            .epoch;
        let current_path = current
            .and_then(|path| navigation_path(Path::new(path)).ok())
            .map(|path| path.to_string_lossy().into_owned());
        let current = current_path.as_deref().or(current);
        if query.trim().is_empty() {
            let files = snapshot
                .recent
                .iter()
                .filter(|p| Some(p.as_str()) != current)
                .take(40)
                .map(|path| QuickFile {
                    path: path.clone(),
                    name: Path::new(path)
                        .file_name()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .into_owned(),
                    title: String::new(),
                    location: String::new(),
                })
                .collect();
            return Ok(QuickResults {
                files,
                ..Default::default()
            });
        }
        let roots = if let Some(scope) = scope {
            let canonical = navigation_path(scope).map_err(storage_error)?;
            if !snapshot
                .values
                .locations
                .iter()
                .any(|root| canonical.starts_with(root))
                && !snapshot.values.favorites.iter().any(|root| {
                    canonical.starts_with(root) && FileWorkspace::open(Path::new(root)).is_ok()
                })
            {
                return Err(error(
                    ErrorCode::Denied,
                    "Folder is not an added navigation location",
                    false,
                ));
            }
            vec![canonical.to_string_lossy().into_owned()]
        } else {
            return Ok(QuickResults::default());
        };
        let mut result = QuickResults::default();
        let mut seen = HashSet::new();
        let mut ranked = vec![];
        let mut budget = IndexBudget { entries: 50_000 };
        for root in roots {
            if budget.entries == 0 {
                result.truncated = true;
                break;
            }
            if cancelled.load(Ordering::Relaxed) {
                result.cancelled = true;
                return Ok(result);
            }
            let (epoch, cached) = {
                let runtime = self
                    .navigation
                    .lock()
                    .map_err(|_| invalid("Navigation lock poisoned"))?;
                (
                    runtime.epoch,
                    runtime
                        .indexes
                        .get(&root)
                        .filter(|(cached_epoch, _)| *cached_epoch == runtime.epoch)
                        .map(|(_, index)| index.clone()),
                )
            };
            let index = if let Some(index) = cached {
                budget.entries = budget.entries.saturating_sub(index.files.len());
                index
            } else {
                let index = Arc::new(build_index(&root, cancelled, &mut budget)?);
                if index.cancelled {
                    return Ok((*index).clone());
                }
                let mut runtime = self
                    .navigation
                    .lock()
                    .map_err(|_| invalid("Navigation lock poisoned"))?;
                if runtime.epoch == epoch {
                    if runtime.indexes.len() >= 64
                        || runtime
                            .indexes
                            .values()
                            .map(|(_, index)| index.files.len())
                            .sum::<usize>()
                            + index.files.len()
                            > 50_000
                    {
                        runtime.indexes.clear();
                    }
                    runtime.indexes.insert(root.clone(), (epoch, index.clone()));
                }
                index
            };
            result.truncated |= index.truncated;
            result.skipped += index.skipped;
            for file in &index.files {
                if seen.insert(file.path.clone()) {
                    if let Some(score) =
                        file_score(query, &file.name, &file.title, &display_path(file))
                    {
                        let recent = snapshot
                            .recent
                            .iter()
                            .position(|p| p == &file.path)
                            .unwrap_or(usize::MAX);
                        ranked.push((score, recent, file.clone()));
                    }
                }
            }
        }
        let current_epoch = self
            .navigation
            .lock()
            .map_err(|_| invalid("Navigation lock poisoned"))?
            .epoch;
        if current_epoch != start_epoch {
            return Ok(QuickResults {
                cancelled: true,
                ..Default::default()
            });
        }
        ranked.sort_by(|a, b| {
            a.0.cmp(&b.0)
                .then(a.1.cmp(&b.1))
                .then(a.2.path.cmp(&b.2.path))
        });
        result.files = ranked
            .into_iter()
            .take(100)
            .map(|(_, _, file)| file)
            .collect();
        result.cancelled = cancelled.load(Ordering::Relaxed);
        Ok(result)
    }
}
struct IndexBudget {
    entries: usize,
}
fn build_index(
    root: &str,
    cancelled: &AtomicBool,
    budget: &mut IndexBudget,
) -> Result<QuickResults, WireError> {
    let files = match FileWorkspace::open(Path::new(root)) {
        Ok(files) => files,
        Err(_) => {
            return Ok(QuickResults {
                skipped: 1,
                ..Default::default()
            });
        }
    };
    let mut result = QuickResults::default();
    let mut pending = vec![(String::new(), 0)];

    while let Some((directory, depth)) = pending.pop() {
        if cancelled.load(Ordering::Relaxed) {
            result.cancelled = true;
            break;
        }
        let listing = match files.list(&directory, false) {
            Ok(list) => list,
            Err(_) => {
                result.skipped += 1;
                continue;
            }
        };
        result.truncated |= listing.truncated;
        for entry in listing.entries {
            if cancelled.load(Ordering::Relaxed) {
                result.cancelled = true;
                return Ok(result);
            }
            if budget.entries == 0 {
                result.truncated = true;
                return Ok(result);
            }
            budget.entries -= 1;
            if entry.directory {
                if depth < 64 {
                    pending.push((entry.path, depth + 1));
                } else {
                    result.truncated = true;
                }
                continue;
            }
            if !Path::new(&entry.name)
                .extension()
                .is_some_and(|ext| supported_browsing_extension(&ext.to_string_lossy()))
            {
                continue;
            }
            result.files.push(QuickFile {
                path: PathBuf::from(root)
                    .join(&entry.path)
                    .to_string_lossy()
                    .into_owned(),
                name: entry.name,
                title: String::new(),
                location: root.into(),
            });
        }
    }
    Ok(result)
}

fn display_path(file: &QuickFile) -> String {
    Path::new(&file.path)
        .strip_prefix(&file.location)
        .unwrap_or(Path::new(&file.path))
        .to_string_lossy()
        .into_owned()
}
