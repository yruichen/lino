use lino_runtime::DocumentRuntime;
use std::{fmt, path::Path, sync::Arc};

#[derive(Debug, uniffi::Error)]
pub enum BridgeError {
    Failed {
        message: String,
    },
    Wire {
        code: String,
        message: String,
        retryable: bool,
    },
}
impl fmt::Display for BridgeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Failed { message } | Self::Wire { message, .. } => write!(f, "{message}"),
        }
    }
}
impl std::error::Error for BridgeError {}

pub(crate) fn wire_error(error: lino_protocol::WireError) -> BridgeError {
    BridgeError::Wire {
        code: serde_json::to_string(&error.code)
            .unwrap_or_else(|_| "\"internal\"".into())
            .trim_matches('"')
            .into(),
        message: error.message,
        retryable: error.retryable,
    }
}
fn json_error(error: serde_json::Error) -> BridgeError {
    BridgeError::Failed {
        message: format!("协议编码失败：{error}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn wire_failure_keeps_reason_and_diagnostic_separate_from_localized_display() {
        let error = wire_error(lino_protocol::WireError {
            code: lino_protocol::ErrorCode::NotSaved,
            retryable: false,
            message: "fixture diagnostic".into(),
        });
        assert!(
            matches!(error, BridgeError::Wire { ref code, ref message, retryable: false }
            if code == "not_saved" && message == "fixture diagnostic")
        );
    }
}
fn intent(json: Option<String>) -> Result<Option<lino_protocol::CloseIntent>, BridgeError> {
    json.map(|value| serde_json::from_str(&value))
        .transpose()
        .map_err(json_error)
}

#[derive(uniffi::Object)]
pub struct DocumentService {
    pub(crate) runtime: Arc<DocumentRuntime>,
}

#[uniffi::export]
impl DocumentService {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            runtime: Arc::new(DocumentRuntime::default()),
        })
    }
    pub fn configure_recovery(&self, path: String) -> Result<(), BridgeError> {
        self.runtime
            .configure_recovery(Path::new(&path))
            .map_err(wire_error)
    }
    pub fn list_recoveries(&self) -> Result<String, BridgeError> {
        serde_json::to_string(&self.runtime.list_recoveries().map_err(wire_error)?)
            .map_err(json_error)
    }
    pub fn restore_recovery(
        &self,
        key: String,
        replace_json: Option<String>,
    ) -> Result<String, BridgeError> {
        serde_json::to_string(
            &self
                .runtime
                .restore_recovery(&key, intent(replace_json)?)
                .map_err(wire_error)?,
        )
        .map_err(json_error)
    }
    pub fn discard_recovery(&self, key: String) -> Result<(), BridgeError> {
        self.runtime.discard_recovery(&key).map_err(wire_error)
    }
    pub fn abandon_document(&self, session_id: String) -> Result<(), BridgeError> {
        self.runtime
            .abandon_document(&session_id)
            .map_err(wire_error)
    }
    pub fn reattach_document(&self, session_id: String) -> Result<String, BridgeError> {
        serde_json::to_string(
            &self
                .runtime
                .reattach_document(&session_id)
                .map_err(wire_error)?,
        )
        .map_err(json_error)
    }
    pub fn new_document(&self, replace_json: Option<String>) -> Result<String, BridgeError> {
        let document = self
            .runtime
            .new_document(intent(replace_json)?)
            .map_err(wire_error)?;
        serde_json::to_string(&document).map_err(json_error)
    }
    pub fn validate_document_file(&self, path: String) -> Result<(), BridgeError> {
        self.runtime
            .validate_document_file(Path::new(&path))
            .map_err(wire_error)
    }
    pub fn open_file(
        &self,
        path: String,
        replace_json: Option<String>,
    ) -> Result<String, BridgeError> {
        let document = self
            .runtime
            .open_file(Path::new(&path), intent(replace_json)?)
            .map_err(wire_error)?;
        serde_json::to_string(&document).map_err(json_error)
    }
    pub fn save_target(&self, path: String) -> Result<String, BridgeError> {
        let target = self
            .runtime
            .save_target(Path::new(&path))
            .map_err(wire_error)?;
        serde_json::to_string(&target).map_err(json_error)
    }
    pub fn release_save_target(&self, target_json: String) -> Result<(), BridgeError> {
        let target = serde_json::from_str(&target_json).map_err(json_error)?;
        self.runtime.release_save_target(target).map_err(wire_error)
    }
    pub fn request(&self, request_json: String) -> Result<String, BridgeError> {
        self.runtime.dispatch(&request_json).map_err(json_error)
    }
}
