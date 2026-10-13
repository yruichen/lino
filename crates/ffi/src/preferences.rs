use crate::{exports::wire_error, BridgeError, DocumentService};
use std::path::Path;
fn json_error(error: serde_json::Error) -> BridgeError {
    BridgeError::Failed {
        message: error.to_string(),
    }
}
#[uniffi::export]
impl DocumentService {
    pub fn configure_preferences(
        &self,
        path: String,
        legacy_language: Option<String>,
        legacy_autosave: Option<bool>,
    ) -> Result<String, BridgeError> {
        serde_json::to_string(
            &self
                .runtime
                .configure_preferences(Path::new(&path), legacy_language, legacy_autosave)
                .map_err(wire_error)?,
        )
        .map_err(json_error)
    }
    pub fn preferences(&self) -> Result<String, BridgeError> {
        serde_json::to_string(&self.runtime.preferences().map_err(wire_error)?).map_err(json_error)
    }
    pub fn update_preferences(
        &self,
        expected_revision: String,
        values_json: String,
    ) -> Result<String, BridgeError> {
        let values = serde_json::from_str(&values_json).map_err(json_error)?;
        serde_json::to_string(
            &self
                .runtime
                .update_preferences(&expected_revision, values)
                .map_err(wire_error)?,
        )
        .map_err(json_error)
    }
}
