use crate::{exports::wire_error, BridgeError, DocumentService};

#[uniffi::export]
impl DocumentService {
    pub fn evaluate_releases(
        &self,
        releases_json: String,
        current_version: String,
        include_prereleases: bool,
    ) -> Result<String, BridgeError> {
        let result = self
            .runtime
            .evaluate_releases(&releases_json, &current_version, include_prereleases)
            .map_err(wire_error)?;
        serde_json::to_string(&result).map_err(|error| BridgeError::Failed {
            message: error.to_string(),
        })
    }
}
