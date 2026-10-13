use crate::{exports::wire_error, BridgeError, DocumentService};
use std::sync::Arc;

#[uniffi::export(callback_interface)]
pub trait DocumentChangeListener: Send + Sync {
    fn changed(&self);
}
#[derive(uniffi::Object)]
pub struct DocumentWatch {
    _watch: lino_runtime::DocumentWatch,
}
#[uniffi::export]
impl DocumentWatch {}
#[uniffi::export]
impl DocumentService {
    pub fn reload_document(
        &self,
        intent_json: String,
        file_ref: String,
    ) -> Result<String, BridgeError> {
        let intent = serde_json::from_str(&intent_json).map_err(|e| BridgeError::Failed {
            message: e.to_string(),
        })?;
        let next = self
            .runtime
            .reload_document(intent, &file_ref)
            .map_err(wire_error)?;
        serde_json::to_string(&next).map_err(|e| BridgeError::Failed {
            message: e.to_string(),
        })
    }
    pub fn watch_document(
        &self,
        session_id: String,
        file_ref: String,
        listener: Box<dyn DocumentChangeListener>,
    ) -> Result<Arc<DocumentWatch>, BridgeError> {
        let listener: Arc<dyn DocumentChangeListener> = Arc::from(listener);
        let watch = self
            .runtime
            .watch_document(&session_id, &file_ref, Arc::new(move || listener.changed()))
            .map_err(wire_error)?;
        Ok(Arc::new(DocumentWatch { _watch: watch }))
    }
    pub fn external_change(
        &self,
        session_id: String,
        file_ref: String,
    ) -> Result<String, BridgeError> {
        self.runtime
            .external_change(&session_id, &file_ref)
            .map_err(wire_error)
    }
    pub fn set_document_read_only(
        &self,
        session_id: String,
        epoch: String,
        revision: String,
        value: bool,
    ) -> Result<String, BridgeError> {
        let value = self
            .runtime
            .set_document_read_only(&session_id, &epoch, &revision, value)
            .map_err(wire_error)?;
        serde_json::to_string(&value).map_err(|e| BridgeError::Failed {
            message: e.to_string(),
        })
    }
}
