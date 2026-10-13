use open_typora_runtime::DocumentRuntime;
use std::{fmt, path::Path, sync::Arc};

#[derive(Debug, uniffi::Error)]
pub enum BridgeError {
    Failed { message: String },
}
impl fmt::Display for BridgeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Failed { message } => write!(f, "{message}"),
        }
    }
}
impl std::error::Error for BridgeError {}

fn wire_error(error: open_typora_protocol::WireError) -> BridgeError {
    BridgeError::Failed {
        message: error.message,
    }
}
fn json_error(error: serde_json::Error) -> BridgeError {
    BridgeError::Failed {
        message: format!("协议编码失败：{error}"),
    }
}
fn intent(json: Option<String>) -> Result<Option<open_typora_protocol::CloseIntent>, BridgeError> {
    json.map(|value| serde_json::from_str(&value))
        .transpose()
        .map_err(json_error)
}

#[derive(uniffi::Object)]
pub struct DocumentService {
    runtime: DocumentRuntime,
}

#[uniffi::export]
impl DocumentService {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            runtime: DocumentRuntime::default(),
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
    pub fn reattach_document(&self) -> Result<String, BridgeError> {
        serde_json::to_string(&self.runtime.reattach_document().map_err(wire_error)?)
            .map_err(json_error)
    }
    pub fn new_document(&self, replace_json: Option<String>) -> Result<String, BridgeError> {
        let document = self
            .runtime
            .new_document(intent(replace_json)?)
            .map_err(wire_error)?;
        serde_json::to_string(&document).map_err(json_error)
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
