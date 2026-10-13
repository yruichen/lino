use crate::{exports::wire_error, BridgeError, DocumentService};

#[derive(uniffi::Record)]
pub struct ImageContent {
    pub bytes: Vec<u8>,
    pub mime: String,
}

#[uniffi::export]
impl DocumentService {
    pub fn copy_save_images(
        &self,
        session_id: String,
        file_ref: Option<String>,
        request_json: String,
    ) -> Result<(), BridgeError> {
        let request = serde_json::from_str(&request_json).map_err(|error| BridgeError::Failed {
            message: error.to_string(),
        })?;
        self.runtime
            .copy_save_images(&session_id, file_ref.as_deref(), request)
            .map_err(wire_error)
    }
    pub fn document_link_path(
        &self,
        session_id: String,
        file_ref: Option<String>,
        source: String,
    ) -> Result<String, BridgeError> {
        self.runtime
            .document_link_path(&session_id, file_ref.as_deref(), &source)
            .map_err(wire_error)
    }
    pub fn read_image(
        &self,
        session_id: String,
        file_ref: Option<String>,
        source: String,
    ) -> Result<ImageContent, BridgeError> {
        let image = self
            .runtime
            .read_image(&session_id, file_ref.as_deref(), &source)
            .map_err(wire_error)?;
        Ok(ImageContent {
            bytes: image.bytes,
            mime: image.mime,
        })
    }
    pub fn import_image_file(
        &self,
        session_id: String,
        file_ref: Option<String>,
        path: String,
    ) -> Result<String, BridgeError> {
        self.runtime
            .import_image_file(
                &session_id,
                file_ref.as_deref(),
                std::path::Path::new(&path),
            )
            .map_err(wire_error)
    }
    pub fn import_image_bytes(
        &self,
        session_id: String,
        file_ref: Option<String>,
        name: String,
        bytes: Vec<u8>,
    ) -> Result<String, BridgeError> {
        self.runtime
            .import_image(&session_id, file_ref.as_deref(), &name, &bytes)
            .map_err(wire_error)
    }
    pub fn image_path(
        &self,
        session_id: String,
        file_ref: Option<String>,
        source: String,
    ) -> Result<String, BridgeError> {
        self.runtime
            .image_path(&session_id, file_ref.as_deref(), &source)
            .map_err(wire_error)
    }
}
