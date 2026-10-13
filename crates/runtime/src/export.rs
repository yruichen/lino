use crate::{
    dispatch::{error, number, storage_error},
    DocumentRuntime,
};
use lino_adapters::assets::FileAssets;
use lino_application::{
    assets::{AssetPort, ImageContent},
    export::ExportSnapshot,
    jobs::{JobLifecycle, JobState},
    ports::DiskVersion,
};
use lino_document::{FileRef, SessionId};
use lino_protocol::{ErrorCode, ExportSource, SaveTarget, WireError};
use std::{
    collections::HashSet,
    path::PathBuf,
    sync::{Arc, Mutex, Weak},
};

#[derive(Default)]
pub(crate) struct Exports {
    next: u64,
    jobs: Vec<Weak<ExportJob>>,
}
pub struct ExportJob {
    id: u64,
    runtime: Arc<DocumentRuntime>,
    input: ExportSnapshot,
    preferences: lino_protocol::EditorPreferences,
    assets: Option<FileAssets>,
    source_path: Option<PathBuf>,
    image_paths: Mutex<HashSet<PathBuf>>,
    state: Mutex<JobLifecycle>,
}
impl DocumentRuntime {
    pub fn begin_export(
        self: &Arc<Self>,
        session: &str,
        epoch: &str,
        revision: &str,
    ) -> Result<Arc<ExportJob>, WireError> {
        let _gate = self
            .file_gate
            .lock()
            .map_err(|_| error(ErrorCode::Internal, "File gate poisoned", false))?;
        let info = self.info(SessionId(number(session)?))?;
        if info.epoch.0 != number(epoch)? {
            return Err(error(ErrorCode::OldEpoch, "View changed", false));
        }
        if info.snapshot.revision().value() != number(revision)? {
            return Err(error(
                ErrorCode::StaleRevision,
                "Export input changed; retry",
                true,
            ));
        }
        let assets = info
            .file
            .map(|file| {
                self.resources
                    .path(file)
                    .map_err(storage_error)
                    .and_then(|path| FileAssets::for_document(&path).map_err(storage_error))
            })
            .transpose()?;
        let source_path = info
            .file
            .map(|file| self.resources.path(file).map_err(storage_error))
            .transpose()?;
        let mut exports = self
            .exports
            .lock()
            .map_err(|_| error(ErrorCode::Internal, "Export registry poisoned", false))?;
        exports
            .jobs
            .retain(|job| job.upgrade().is_some_and(|job| job.running()));
        if exports.jobs.len() >= 4 {
            return Err(error(
                ErrorCode::Busy,
                "Four exports are already running",
                true,
            ));
        }
        exports.next = exports.next.checked_add(1).ok_or_else(|| {
            error(
                ErrorCode::ResourceLimit,
                "Export identities exhausted",
                false,
            )
        })?;
        let job = Arc::new(ExportJob {
            id: exports.next,
            runtime: self.clone(),
            input: ExportSnapshot {
                owner: info.id,
                source: info.snapshot,
                label: info.label,
            },
            preferences: self.preferences()?.values,
            assets,
            source_path,
            image_paths: Mutex::default(),
            state: Mutex::default(),
        });
        exports.jobs.push(Arc::downgrade(&job));
        Ok(job)
    }
}
impl ExportJob {
    fn failure(message: &str) -> WireError {
        error(ErrorCode::UnsupportedOperation, message, false)
    }
    fn running(&self) -> bool {
        self.state
            .lock()
            .map(|state| matches!(state.state(), JobState::Running | JobState::Committing))
            .unwrap_or(false)
    }
    fn check(&self) -> Result<(), WireError> {
        self.runtime.info(self.input.owner)?;
        if self
            .state
            .lock()
            .map(|state| state.state() == JobState::Running)
            .unwrap_or(false)
        {
            Ok(())
        } else {
            Err(Self::failure("Export cancelled or finished"))
        }
    }
    pub fn source(&self) -> Result<ExportSource, WireError> {
        self.check()?;
        Ok(ExportSource {
            job_id: self.id.to_string(),
            session_id: self.input.owner.0.to_string(),
            revision: self.input.source.revision().value().to_string(),
            text: self.input.source.text().into(),
            label: self.input.label.clone(),
            preferences: self.preferences.clone(),
        })
    }
    pub fn read_image(&self, source: &str) -> Result<ImageContent, WireError> {
        self.check()?;
        let assets = self.assets.as_ref().ok_or_else(|| {
            error(
                ErrorCode::NotSaved,
                "Local export images require a saved document",
                false,
            )
        })?;
        let image = assets.read_image(source).map_err(storage_error)?;
        let path = assets.resolve(source).map_err(storage_error)?;
        self.image_paths
            .lock()
            .map_err(|_| Self::failure("Export resource state poisoned"))?
            .insert(path);
        self.check()?;
        Ok(image)
    }
    pub fn cancel(&self) -> bool {
        self.state
            .lock()
            .map(|mut state| state.cancel())
            .unwrap_or(false)
    }
    pub fn commit(&self, target: SaveTarget, bytes: &[u8]) -> Result<bool, WireError> {
        let _gate = self
            .runtime
            .file_gate
            .lock()
            .map_err(|_| error(ErrorCode::Internal, "File gate poisoned", false))?;
        self.check()?;
        self.runtime.validate_target(&target)?;
        let file = FileRef(number(&target.file_ref)?);
        let path = self.runtime.resources.path(file).map_err(storage_error)?;
        if self.source_path.as_ref() == Some(&path)
            || self
                .image_paths
                .lock()
                .map_err(|_| Self::failure("Export resource state poisoned"))?
                .contains(&path)
        {
            return Err(error(
                ErrorCode::Denied,
                "Export cannot overwrite its source or resources",
                false,
            ));
        }
        if self.runtime.lock()?.references(file) {
            return Err(error(
                ErrorCode::Denied,
                "Export cannot overwrite an open document",
                false,
            ));
        }
        self.state
            .lock()
            .map_err(|_| Self::failure("Export state poisoned"))?
            .begin_commit()
            .map_err(Self::failure)?;
        let result = self
            .runtime
            .resources
            .commit_bytes(file, target.expected_version.map(DiskVersion), bytes)
            .map_err(storage_error);
        self.state
            .lock()
            .map_err(|_| Self::failure("Export state poisoned"))?
            .finish(result.is_ok());
        result.map(|(_, durable)| durable)
    }
    pub fn begin_print(&self) -> Result<(), WireError> {
        self.check()?;
        self.state
            .lock()
            .map_err(|_| Self::failure("Export state poisoned"))?
            .begin_commit()
            .map_err(Self::failure)
    }
    pub fn finish_print(&self, success: bool) -> Result<(), WireError> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| Self::failure("Export state poisoned"))?;
        if state.state() == JobState::Cancelled {
            return Err(Self::failure("Export cancelled"));
        }
        if state.state() != JobState::Committing {
            return Err(Self::failure("Print was not submitted"));
        }
        state.finish(success);
        Ok(())
    }
}
