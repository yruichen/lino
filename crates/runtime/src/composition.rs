use crate::dispatch::{close_intent, document_error, storage_error, to_opened};
use open_typora_adapters::storage::FileStorage;
use open_typora_application::{
    documents::{CloseIntent, DocumentInfo, Documents},
    ports::StoragePort,
};
use open_typora_document::FileRef;
use open_typora_protocol::{OpenedDocument, SaveTarget, WireError};
use std::{
    path::Path,
    sync::{Arc, Mutex, MutexGuard},
};

pub struct DocumentRuntime {
    pub(crate) documents: Mutex<Documents>,
    pub(crate) recovery: Mutex<crate::recovery::RecoveryState>,
    pub(crate) storage: Arc<dyn StoragePort>,
    pub(crate) resources: Arc<FileStorage>,
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
            documents: Mutex::new(Documents::default()),
            recovery: Mutex::default(),
            storage,
            resources,
        }
    }
    pub(crate) fn lock(&self) -> Result<MutexGuard<'_, Documents>, WireError> {
        self.documents.lock().map_err(|_| {
            crate::dispatch::error(
                open_typora_protocol::ErrorCode::Internal,
                "文档状态锁异常；未继续修改状态。",
                false,
            )
        })
    }
    pub(crate) fn release_unused(&self, file: Option<FileRef>) {
        if let Some(file) = file {
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
        replace: Option<open_typora_protocol::CloseIntent>,
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
        replace: Option<open_typora_protocol::CloseIntent>,
    ) -> Result<OpenedDocument, WireError> {
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
        self.release_unused(Some(file));
        let info = result?;
        self.release_unused(previous);
        Ok(to_opened(info))
    }
    pub fn save_target(&self, path: &Path) -> Result<SaveTarget, WireError> {
        let (file, label) = self.resources.register(path).map_err(storage_error)?;
        match self.storage.inspect(file) {
            Ok(version) => Ok(SaveTarget {
                file_ref: file.0.to_string(),
                expected_version: version.map(|v| v.0),
                label,
            }),
            Err(error) => {
                self.release_unused(Some(file));
                Err(storage_error(error))
            }
        }
    }
    pub fn release_save_target(&self, target: SaveTarget) -> Result<(), WireError> {
        self.release_unused(Some(FileRef(crate::dispatch::number(&target.file_ref)?)));
        Ok(())
    }
    pub(crate) fn info(
        &self,
        id: open_typora_document::SessionId,
    ) -> Result<DocumentInfo, WireError> {
        self.lock()?.info(id).map_err(document_error)
    }
}
