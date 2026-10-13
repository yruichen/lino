use crate::{assets::ImageContent, exports::wire_error, BridgeError, DocumentService};
use std::sync::Arc;
#[derive(uniffi::Object)]
pub struct ExportJob {
    job: Arc<lino_runtime::export::ExportJob>,
}
#[uniffi::export]
impl DocumentService {
    pub fn begin_export(
        &self,
        session_id: String,
        epoch: String,
        revision: String,
    ) -> Result<Arc<ExportJob>, BridgeError> {
        Ok(Arc::new(ExportJob {
            job: self
                .runtime
                .begin_export(&session_id, &epoch, &revision)
                .map_err(wire_error)?,
        }))
    }
}
#[uniffi::export]
impl ExportJob {
    pub fn source(&self) -> Result<String, BridgeError> {
        serde_json::to_string(&self.job.source().map_err(wire_error)?).map_err(|e| {
            BridgeError::Failed {
                message: e.to_string(),
            }
        })
    }
    pub fn read_image(&self, source: String) -> Result<ImageContent, BridgeError> {
        let image = self.job.read_image(&source).map_err(wire_error)?;
        Ok(ImageContent {
            bytes: image.bytes,
            mime: image.mime,
        })
    }
    pub fn cancel(&self) -> bool {
        self.job.cancel()
    }
    pub fn commit(&self, target_json: String, bytes: Vec<u8>) -> Result<bool, BridgeError> {
        let target = serde_json::from_str(&target_json).map_err(|e| BridgeError::Failed {
            message: e.to_string(),
        })?;
        self.job.commit(target, &bytes).map_err(wire_error)
    }
    pub fn begin_print(&self) -> Result<(), BridgeError> {
        self.job.begin_print().map_err(wire_error)
    }
    pub fn finish_print(&self, success: bool) -> Result<(), BridgeError> {
        self.job.finish_print(success).map_err(wire_error)
    }
}
