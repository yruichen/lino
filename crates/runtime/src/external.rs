use crate::{
    dispatch::{document_error, error, number, storage_error, to_opened},
    DocumentRuntime,
};
use lino_document::{EditorEpoch, SessionId};
use lino_protocol::{ErrorCode, OpenedDocument, WireError};
use std::sync::Arc;
pub struct DocumentWatch {
    _watch: lino_adapters::watcher::FileWatch,
}
impl DocumentRuntime {
    pub fn reload_document(
        &self,
        intent: lino_protocol::CloseIntent,
        expected_file: &str,
    ) -> Result<OpenedDocument, WireError> {
        let _gate = self
            .file_gate
            .lock()
            .map_err(|_| error(ErrorCode::Internal, "File gate poisoned", false))?;
        let intent = crate::dispatch::close_intent(intent)?;
        let info = self.info(intent.session)?;
        let file = info
            .file
            .ok_or_else(|| error(ErrorCode::NotSaved, "Document has no file", false))?;
        if file.0.to_string() != expected_file {
            return Err(error(
                ErrorCode::StaleRevision,
                "Document file binding changed",
                false,
            ));
        }
        let loaded = self.storage.load(file).map_err(storage_error)?;
        // Decode before retiring the original recovery/session. Failed loads preserve it.
        let next = self.transition(Some(intent), |docs, intent| {
            docs.reload(file, loaded, intent.unwrap())
        })?;
        Ok(to_opened(next))
    }
    pub fn watch_document(
        &self,
        session: &str,
        expected_file: &str,
        changed: Arc<dyn Fn() + Send + Sync>,
    ) -> Result<DocumentWatch, WireError> {
        let _gate = self
            .file_gate
            .lock()
            .map_err(|_| error(ErrorCode::Internal, "File gate poisoned", false))?;
        let info = self.info(SessionId(number(session)?))?;
        let file = info
            .file
            .ok_or_else(|| error(ErrorCode::NotSaved, "Document has no file", false))?;
        if file.0.to_string() != expected_file {
            return Err(error(
                ErrorCode::StaleRevision,
                "Document file binding changed",
                false,
            ));
        }
        let path = self.resources.path(file).map_err(storage_error)?;
        Ok(DocumentWatch {
            _watch: lino_adapters::watcher::FileWatch::new(&path, changed)
                .map_err(storage_error)?,
        })
    }
    /// Notifications merely invalidate. Disk inspection and binding identity decide.
    pub fn external_change(&self, session: &str, expected_file: &str) -> Result<String, WireError> {
        let _gate = self
            .file_gate
            .lock()
            .map_err(|_| error(ErrorCode::Internal, "File gate poisoned", false))?;
        let id = SessionId(number(session)?);
        let docs = self.lock()?;
        let info = docs.info(id).map_err(document_error)?;
        let file = info
            .file
            .ok_or_else(|| error(ErrorCode::NotSaved, "Document has no file", false))?;
        if file.0.to_string() != expected_file {
            return Err(error(
                ErrorCode::StaleRevision,
                "Document file binding changed",
                false,
            ));
        }
        let expected = docs.disk_version(id).map_err(document_error)?;
        drop(docs);
        let actual = self.storage.inspect(file).map_err(storage_error)?;
        Ok(if actual.is_none() {
            "deleted"
        } else if actual == expected {
            "unchanged"
        } else {
            "changed"
        }
        .into())
    }
    pub fn set_document_read_only(
        &self,
        session: &str,
        epoch: &str,
        revision: &str,
        value: bool,
    ) -> Result<lino_protocol::DocumentStatus, WireError> {
        let info = self
            .lock()?
            .set_read_only(
                SessionId(number(session)?),
                EditorEpoch(number(epoch)?),
                number(revision)?,
                value,
            )
            .map_err(document_error)?;
        Ok(crate::dispatch::status(info))
    }
}
