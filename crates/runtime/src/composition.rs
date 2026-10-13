use crate::dispatch::{close_intent, document_error, storage_error, to_opened};
use lino_adapters::storage::FileStorage;
use lino_application::{
    documents::{CloseIntent, DocumentInfo, Documents},
    ports::StoragePort,
};
use lino_document::FileRef;
use lino_protocol::{OpenedDocument, SaveTarget, WireError};
use std::{
    collections::HashMap,
    path::Path,
    sync::{Arc, Mutex, MutexGuard},
};

pub struct DocumentRuntime {
    pub(crate) file_gate: Mutex<()>,
    pub(crate) documents: Mutex<Documents>,
    pub(crate) recovery: Mutex<crate::recovery::RecoveryState>,
    pub(crate) preferences: Mutex<crate::preferences::PreferenceRuntime>,
    pub(crate) exports: Mutex<crate::export::Exports>,
    pub(crate) storage: Arc<dyn StoragePort>,
    pub(crate) resources: Arc<FileStorage>,
    reservations: Mutex<TargetReservations>,
}
#[derive(Default)]
struct TargetReservations {
    next: u64,
    targets: HashMap<u64, FileRef>,
}

impl Default for DocumentRuntime {
    fn default() -> Self {
        let resources = Arc::new(FileStorage::default());
        Self::from_ports(resources.clone(), resources)
    }
}

impl DocumentRuntime {
    pub fn from_ports(resources: Arc<FileStorage>, storage: Arc<dyn StoragePort>) -> Self {
        Self {
            file_gate: Mutex::new(()),
            documents: Mutex::new(Documents::default()),
            recovery: Mutex::default(),
            preferences: Mutex::default(),
            exports: Mutex::default(),
            storage,
            resources,
            reservations: Mutex::default(),
        }
    }
    pub(crate) fn lock(&self) -> Result<MutexGuard<'_, Documents>, WireError> {
        self.documents.lock().map_err(|_| {
            crate::dispatch::error(
                lino_protocol::ErrorCode::Internal,
                "文档状态锁异常；未继续修改状态。",
                false,
            )
        })
    }
    pub(crate) fn release_unused(&self, file: Option<FileRef>) {
        if let Ok(_gate) = self.file_gate.lock() {
            self.release_unused_in_gate(file);
        }
    }
    pub(crate) fn release_unused_in_gate(&self, file: Option<FileRef>) {
        if let Some(file) = file {
            if self
                .reservations
                .lock()
                .map(|reservations| reservations.targets.values().any(|target| *target == file))
                .unwrap_or(true)
            {
                return;
            }
            if self
                .documents
                .lock()
                .map(|documents| !documents.references(file))
                .unwrap_or(false)
            {
                self.resources.unregister(file);
            }
        }
    }
    pub(crate) fn previous_file(
        &self,
        replace: &Option<CloseIntent>,
    ) -> Result<Option<FileRef>, WireError> {
        replace
            .as_ref()
            .map(|intent| {
                self.lock()?
                    .info(intent.session)
                    .map(|info| info.file)
                    .map_err(document_error)
            })
            .transpose()
            .map(|file| file.flatten())
    }
    pub fn new_document(
        &self,
        replace: Option<lino_protocol::CloseIntent>,
    ) -> Result<OpenedDocument, WireError> {
        let replace = replace.map(close_intent).transpose()?;
        let previous = self.previous_file(&replace)?;
        let info = self.transition(replace, |docs, replace| docs.new_document(replace))?;
        self.release_unused(previous);
        Ok(to_opened(info))
    }
    pub fn open_file(
        &self,
        path: &Path,
        replace: Option<lino_protocol::CloseIntent>,
    ) -> Result<OpenedDocument, WireError> {
        let _gate = self.file_gate.lock().map_err(|_| {
            crate::dispatch::error(
                lino_protocol::ErrorCode::Internal,
                "File gate poisoned",
                false,
            )
        })?;
        let replace = replace.map(close_intent).transpose()?;
        let previous = self.previous_file(&replace)?;
        let (file, _) = self.resources.register(path).map_err(storage_error)?;
        // Read/decode before replacing anything; invalid input keeps the old session.
        let result = self
            .storage
            .load(file)
            .map_err(storage_error)
            .and_then(|loaded| {
                self.transition(replace, |docs, replace| docs.open(file, loaded, replace))
            });
        self.release_unused_in_gate(Some(file));
        let info = result?;
        self.release_unused_in_gate(previous);
        Ok(to_opened(info))
    }
    pub fn save_target(&self, path: &Path) -> Result<SaveTarget, WireError> {
        let _gate = self.file_gate.lock().map_err(|_| {
            crate::dispatch::error(
                lino_protocol::ErrorCode::Internal,
                "File gate poisoned",
                false,
            )
        })?;
        let (file, label) = self.resources.register(path).map_err(storage_error)?;
        match self.storage.inspect(file) {
            Ok(version) => {
                let mut reservations = self.reservations.lock().map_err(|_| {
                    crate::dispatch::error(
                        lino_protocol::ErrorCode::Internal,
                        "Target reservation lock poisoned",
                        false,
                    )
                })?;
                if reservations.targets.len() >= 256 {
                    drop(reservations);
                    self.release_unused_in_gate(Some(file));
                    return Err(crate::dispatch::error(
                        lino_protocol::ErrorCode::ResourceLimit,
                        "Too many reserved save targets",
                        false,
                    ));
                }
                reservations.next = reservations.next.checked_add(1).ok_or_else(|| {
                    crate::dispatch::error(
                        lino_protocol::ErrorCode::ResourceLimit,
                        "Target identity exhausted",
                        false,
                    )
                })?;
                let id = reservations.next;
                reservations.targets.insert(id, file);
                Ok(SaveTarget {
                    file_ref: file.0.to_string(),
                    expected_version: version.map(|v| v.0),
                    label,
                    reservation_id: Some(id.to_string()),
                })
            }
            Err(error) => {
                self.release_unused_in_gate(Some(file));
                Err(storage_error(error))
            }
        }
    }
    pub fn release_save_target(&self, target: SaveTarget) -> Result<(), WireError> {
        let _gate = self.file_gate.lock().map_err(|_| {
            crate::dispatch::error(
                lino_protocol::ErrorCode::Internal,
                "File gate poisoned",
                false,
            )
        })?;
        let file = FileRef(crate::dispatch::number(&target.file_ref)?);
        if let Some(id) = target.reservation_id {
            let id = crate::dispatch::number(&id)?;
            let mut reservations = self.reservations.lock().map_err(|_| {
                crate::dispatch::error(
                    lino_protocol::ErrorCode::Internal,
                    "Target reservation lock poisoned",
                    false,
                )
            })?;
            if let Some(existing) = reservations.targets.get(&id) {
                if *existing != file {
                    return Err(crate::dispatch::error(
                        lino_protocol::ErrorCode::InvalidTicket,
                        "Save target reservation mismatch",
                        false,
                    ));
                }
                reservations.targets.remove(&id);
            }
        }
        self.release_unused_in_gate(Some(file));
        Ok(())
    }
    pub(crate) fn validate_target(&self, target: &SaveTarget) -> Result<(), WireError> {
        if let Some(id) = &target.reservation_id {
            let id = crate::dispatch::number(id)?;
            let file = FileRef(crate::dispatch::number(&target.file_ref)?);
            let reservations = self.reservations.lock().map_err(|_| {
                crate::dispatch::error(
                    lino_protocol::ErrorCode::Internal,
                    "Target reservation lock poisoned",
                    false,
                )
            })?;
            if reservations.targets.get(&id) != Some(&file) {
                return Err(crate::dispatch::error(
                    lino_protocol::ErrorCode::InvalidTicket,
                    "Save target reservation expired",
                    false,
                ));
            }
        }
        Ok(())
    }
    pub(crate) fn info(&self, id: lino_document::SessionId) -> Result<DocumentInfo, WireError> {
        self.lock()?.info(id).map_err(document_error)
    }
}

impl DocumentRuntime {
    pub fn document_path(&self, session_id: &str) -> Result<Option<String>, WireError> {
        let info = self.info(lino_document::SessionId(crate::dispatch::number(
            session_id,
        )?))?;
        info.file
            .map(|file| {
                self.resources
                    .path(file)
                    .map(|path| path.to_string_lossy().into_owned())
                    .map_err(storage_error)
            })
            .transpose()
    }
    pub fn file_session(&self, path: &Path) -> Result<Option<String>, WireError> {
        let _gate = self.file_gate.lock().map_err(|_| {
            crate::dispatch::error(
                lino_protocol::ErrorCode::Internal,
                "File gate poisoned",
                false,
            )
        })?;
        let (file, _) = self.resources.register(path).map_err(storage_error)?;
        let result = self.lock()?.file_session(file).map(|id| id.0.to_string());
        self.release_unused_in_gate(Some(file));
        Ok(result)
    }
}
