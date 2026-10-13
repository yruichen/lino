//! Image resource use cases; no platform path or UI state.
use crate::ports::StorageError;

pub const MAX_IMAGE_BYTES: usize = 16 * 1024 * 1024;
#[derive(Clone, Debug)]
pub struct ImageContent {
    pub bytes: Vec<u8>,
    pub mime: String,
}
pub trait AssetPort: Send + Sync {
    fn read_image(&self, source: &str) -> Result<ImageContent, StorageError>;
    fn import_image(&self, name: &str, bytes: &[u8]) -> Result<String, StorageError>;
}
/// Sniff bytes instead of trusting the file extension supplied by a document.
pub fn image_mime(bytes: &[u8]) -> Result<&'static str, StorageError> {
    if bytes.is_empty() || bytes.len() > MAX_IMAGE_BYTES {
        return Err(StorageError::LimitExceeded);
    }
    let mime = if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        "image/png"
    } else if bytes.starts_with(b"\xff\xd8\xff") {
        "image/jpeg"
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        "image/gif"
    } else if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") {
        "image/webp"
    } else if bytes.starts_with(b"BM") {
        "image/bmp"
    } else if bytes.starts_with(b"II*\0") || bytes.starts_with(b"MM\0*") {
        "image/tiff"
    } else if bytes.get(4..8) == Some(b"ftyp")
        && bytes
            .get(8..12)
            .is_some_and(|brand| matches!(brand, b"avif" | b"avis"))
    {
        "image/avif"
    } else if bytes.get(4..8) == Some(b"ftyp")
        && bytes
            .get(8..12)
            .is_some_and(|brand| matches!(brand, b"heic" | b"heix" | b"mif1"))
    {
        "image/heic"
    } else if std::str::from_utf8(bytes).ok().is_some_and(|text| {
        let text = text.trim_start_matches('\u{feff}').trim_start();
        text.starts_with("<svg ")
            || text.starts_with("<svg>")
            || (text.starts_with("<?xml")
                && text
                    .as_bytes()
                    .windows(4)
                    .take(1024)
                    .any(|part| part == b"<svg"))
    }) {
        "image/svg+xml"
    } else {
        return Err(StorageError::UnsupportedFile);
    };
    Ok(mime)
}
