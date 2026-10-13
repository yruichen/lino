use crate::{
    dispatch::{error, number, storage_error},
    DocumentRuntime,
};
use lino_adapters::assets::{read_selected, FileAssets};
use lino_application::assets::{AssetPort, ImageContent};
use lino_document::SessionId;
use lino_protocol::{ErrorCode, WireError};
use std::path::Path;

impl DocumentRuntime {
    pub fn copy_save_images(
        &self,
        session: &str,
        expected_file: Option<&str>,
        request: lino_protocol::SaveImagesRequest,
    ) -> Result<(), WireError> {
        let _gate = self
            .file_gate
            .lock()
            .map_err(|_| error(ErrorCode::Internal, "File gate poisoned", false))?;
        self.validate_target(&request.target)?;
        let ticket = self
            .lock()?
            .save_resources(SessionId(number(session)?), number(&request.ticket_id)?)
            .map_err(crate::dispatch::document_error)?;
        if ticket.request.target.0 != number(&request.target.file_ref)?
            || ticket.request.expected.as_ref().map(|value| &value.0)
                != request.target.expected_version.as_ref()
        {
            return Err(error(
                ErrorCode::InvalidTicket,
                "Resource target does not match the saved snapshot",
                false,
            ));
        }
        let assets = self.assets(session, expected_file)?;
        let target = self
            .resources
            .path(ticket.request.target)
            .map_err(storage_error)?;
        assets
            .copy_to(&target, &request.sources)
            .map_err(storage_error)
    }
    fn assets(&self, session: &str, expected_file: Option<&str>) -> Result<FileAssets, WireError> {
        let file = self
            .info(SessionId(number(session)?))?
            .file
            .ok_or_else(|| {
                error(
                    ErrorCode::NotSaved,
                    "Save the document before using local image resources",
                    false,
                )
            })?;
        if expected_file.map(number).transpose()? != Some(file.0) {
            return Err(error(
                ErrorCode::StaleRevision,
                "The document image location changed; retry from the current view",
                false,
            ));
        }
        FileAssets::for_document(&self.resources.path(file).map_err(storage_error)?)
            .map_err(storage_error)
    }
    pub fn read_image(
        &self,
        session: &str,
        expected_file: Option<&str>,
        source: &str,
    ) -> Result<ImageContent, WireError> {
        let _gate = self
            .file_gate
            .lock()
            .map_err(|_| error(ErrorCode::Internal, "File gate poisoned", false))?;
        self.assets(session, expected_file)?
            .read_image(source)
            .map_err(storage_error)
    }
    pub fn import_image(
        &self,
        session: &str,
        expected_file: Option<&str>,
        name: &str,
        bytes: &[u8],
    ) -> Result<String, WireError> {
        let _gate = self
            .file_gate
            .lock()
            .map_err(|_| error(ErrorCode::Internal, "File gate poisoned", false))?;
        self.assets(session, expected_file)?
            .import_image(name, bytes)
            .map_err(storage_error)
    }
    pub fn import_image_file(
        &self,
        session: &str,
        expected_file: Option<&str>,
        path: &Path,
    ) -> Result<String, WireError> {
        // Called only from an explicit host file selection, never a Web path.
        let image = read_selected(path).map_err(storage_error)?;
        self.import_image(
            session,
            expected_file,
            path.file_name().and_then(|s| s.to_str()).unwrap_or("image"),
            &image.bytes,
        )
    }
    pub fn image_path(
        &self,
        session: &str,
        expected_file: Option<&str>,
        source: &str,
    ) -> Result<String, WireError> {
        let _gate = self
            .file_gate
            .lock()
            .map_err(|_| error(ErrorCode::Internal, "File gate poisoned", false))?;
        let assets = self.assets(session, expected_file)?;
        assets.read_image(source).map_err(storage_error)?;
        Ok(assets
            .resolve(source)
            .map_err(storage_error)?
            .to_string_lossy()
            .into_owned())
    }
    pub fn document_link_path(
        &self,
        session: &str,
        expected_file: Option<&str>,
        source: &str,
    ) -> Result<String, WireError> {
        let _gate = self
            .file_gate
            .lock()
            .map_err(|_| error(ErrorCode::Internal, "File gate poisoned", false))?;
        let path = self
            .assets(session, expected_file)?
            .resolve(source)
            .map_err(storage_error)?;
        if let Some(extension) = path.extension().and_then(|value| value.to_str()) {
            if !["md", "markdown", "mdown", "mkd", "txt"]
                .contains(&extension.to_ascii_lowercase().as_str())
            {
                return Err(error(
                    ErrorCode::UnsupportedOperation,
                    "This local link is not a supported text document",
                    false,
                ));
            }
        }
        Ok(path.to_string_lossy().into_owned())
    }
}
