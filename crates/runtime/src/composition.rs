use crate::dispatch::{close_intent, document_error, storage_error, to_opened};
use lino_adapters::storage::FileStorage;
use lino_application::{
    document_types::DocumentKind,
    documents::{CloseIntent, DocumentInfo, Documents},
    ports::{CompilerPort, StoragePort},
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
    pub(crate) navigation: Mutex<crate::navigation::NavigationRuntime>,
    pub(crate) preferences: Mutex<crate::preferences::PreferenceRuntime>,
    pub(crate) exports: Mutex<crate::export::Exports>,
    pub(crate) compiles: Mutex<crate::compile::Compiles>,
    pub(crate) request_cache: Mutex<crate::dispatch::RequestCache>,
    pub(crate) storage: Arc<dyn StoragePort>,
    pub(crate) compiler: Arc<dyn CompilerPort>,
    pub(crate) resources: Arc<FileStorage>,
    reservations: Mutex<TargetReservations>,
}
#[derive(Clone)]
struct TargetReservation {
    file: FileRef,
    expected: Option<String>,
    label: String,
}
#[derive(Default)]
struct TargetReservations {
    next: u64,
    targets: HashMap<u64, TargetReservation>,
}

impl Default for DocumentRuntime {
    fn default() -> Self {
        let resources = Arc::new(FileStorage::default());
        Self::from_ports(resources.clone(), resources)
    }
}

impl DocumentRuntime {
    pub fn from_ports(resources: Arc<FileStorage>, storage: Arc<dyn StoragePort>) -> Self {
        let compiler: Arc<dyn CompilerPort> = Arc::new(
            lino_adapters::compiler::LatexCompiler::new(resources.clone()),
        );
        Self::with_compiler(resources, storage, compiler)
    }

    pub fn with_compiler(
        resources: Arc<FileStorage>,
        storage: Arc<dyn StoragePort>,
        compiler: Arc<dyn CompilerPort>,
    ) -> Self {
        Self {
            file_gate: Mutex::new(()),
            documents: Mutex::new(Documents::default()),
            recovery: Mutex::default(),
            preferences: Mutex::default(),
            navigation: Mutex::default(),
            exports: Mutex::default(),
            compiles: Mutex::default(),
            request_cache: Mutex::default(),
            storage,
            compiler,
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
                .map(|reservations| {
                    reservations
                        .targets
                        .values()
                        .any(|target| target.file == file)
                })
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
    pub fn validate_document_file(&self, path: &Path) -> Result<(), WireError> {
        let extension = path
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or_default();
        if !DocumentKind::supports_extension(extension) {
            return Err(crate::dispatch::error(
                lino_protocol::ErrorCode::UnsupportedFile,
                "Unsupported document format",
                false,
            ));
        }
        let _gate = self.file_gate.lock().map_err(|_| {
            crate::dispatch::error(
                lino_protocol::ErrorCode::Internal,
                "File gate poisoned",
                false,
            )
        })?;
        let (file, _) = self.resources.register(path).map_err(storage_error)?;
        let inspected = self.storage.inspect(file).map_err(storage_error);
        self.release_unused_in_gate(Some(file));
        inspected.map(|_| ())
    }
    pub fn open_file(
        &self,
        path: &Path,
        replace: Option<lino_protocol::CloseIntent>,
    ) -> Result<OpenedDocument, WireError> {
        self.validate_document_file(path)?;
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
        let kind = DocumentKind::from_extension(
            path.extension()
                .and_then(|value| value.to_str())
                .unwrap_or_default(),
        )
        .ok_or_else(|| {
            crate::dispatch::error(
                lino_protocol::ErrorCode::UnsupportedFile,
                "Unsupported document format",
                false,
            )
        })?;
        let result = self
            .storage
            .load(file)
            .map_err(storage_error)
            .and_then(|loaded| {
                self.transition(replace, |docs, replace| {
                    docs.open(file, loaded, kind, replace)
                })
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
                let Some(next) = reservations.next.checked_add(1) else {
                    drop(reservations);
                    self.release_unused_in_gate(Some(file));
                    return Err(crate::dispatch::error(
                        lino_protocol::ErrorCode::ResourceLimit,
                        "Target identity exhausted",
                        false,
                    ));
                };
                reservations.next = next;
                let id = reservations.next;
                let expected_version = version.map(|v| v.0);
                reservations.targets.insert(
                    id,
                    TargetReservation {
                        file,
                        expected: expected_version.clone(),
                        label: label.clone(),
                    },
                );
                Ok(SaveTarget {
                    file_ref: file.0.to_string(),
                    expected_version,
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
                if existing.file != file {
                    return Err(crate::dispatch::error(
                        lino_protocol::ErrorCode::InvalidTicket,
                        "Save target reservation mismatch",
                        false,
                    ));
                }
                reservations.targets.remove(&id);
            }
        } else {
            // Legacy messages did not carry a reservation identity. Release
            // only an unambiguous reservation; never release another window's
            // lease when two native targets point at the same file.
            let mut reservations = self.reservations.lock().map_err(|_| {
                crate::dispatch::error(
                    lino_protocol::ErrorCode::Internal,
                    "Target reservation lock poisoned",
                    false,
                )
            })?;
            let matches: Vec<u64> = reservations
                .targets
                .iter()
                .filter_map(|(id, reservation)| (reservation.file == file).then_some(*id))
                .collect();
            if matches.len() == 1 {
                reservations.targets.remove(&matches[0]);
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
            let reservation = reservations.targets.get(&id).ok_or_else(|| {
                crate::dispatch::error(
                    lino_protocol::ErrorCode::InvalidTicket,
                    "Save target reservation expired",
                    false,
                )
            })?;
            if reservation.file != file
                || reservation.expected.as_deref() != target.expected_version.as_deref()
                || reservation.label != target.label
            {
                return Err(crate::dispatch::error(
                    lino_protocol::ErrorCode::InvalidTicket,
                    "Save target reservation changed",
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
