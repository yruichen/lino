use crate::{exports::wire_error, BridgeError, DocumentService};
use std::sync::Arc;

#[derive(uniffi::Object)]
pub struct CompileJob {
    job: Arc<lino_runtime::CompileJob>,
}

#[uniffi::export]
impl DocumentService {
    pub fn begin_compile(
        &self,
        session_id: String,
        epoch: String,
        profile_json: String,
    ) -> Result<Arc<CompileJob>, BridgeError> {
        let profile = serde_json::from_str(&profile_json).map_err(|error| BridgeError::Failed {
            message: format!("Invalid compile profile: {error}"),
        })?;
        Ok(Arc::new(CompileJob {
            job: self
                .runtime
                .begin_document_compile(&session_id, &epoch, profile)
                .map_err(wire_error)?,
        }))
    }
}

#[uniffi::export]
impl CompileJob {
    pub fn run(&self) -> Result<(), BridgeError> {
        self.job.run().map_err(wire_error)
    }

    pub fn cancel(&self) -> bool {
        self.job.cancel()
    }

    pub fn status(&self) -> Result<String, BridgeError> {
        serde_json::to_string(&self.job.status().map_err(wire_error)?).map_err(|error| {
            BridgeError::Failed {
                message: error.to_string(),
            }
        })
    }

    pub fn pdf(&self) -> Result<Vec<u8>, BridgeError> {
        self.job.pdf().map_err(wire_error)
    }
}
