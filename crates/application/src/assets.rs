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
fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = 0xffff_ffffu32;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            crc = if crc & 1 != 0 {
                (crc >> 1) ^ 0xedb8_8320
            } else {
                crc >> 1
            };
        }
    }
    !crc
}
fn valid_png(bytes: &[u8]) -> bool {
    if !bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        return false;
    }
    let mut offset = 8;
    let mut header = false;
    while offset + 12 <= bytes.len() {
        let Some(length_bytes) = bytes.get(offset..offset + 4) else {
            return false;
        };
        let length = u32::from_be_bytes([
            length_bytes[0],
            length_bytes[1],
            length_bytes[2],
            length_bytes[3],
        ]) as usize;
        let data_start = offset + 8;
        let data_end = match data_start.checked_add(length) {
            Some(value) if value.checked_add(4).is_some_and(|end| end <= bytes.len()) => value,
            _ => return false,
        };
        let chunk_end = data_end + 4;
        let chunk_type = &bytes[offset + 4..data_start];
        let Some(crc_bytes) = bytes.get(data_end..chunk_end) else {
            return false;
        };
        let expected_crc =
            u32::from_be_bytes([crc_bytes[0], crc_bytes[1], crc_bytes[2], crc_bytes[3]]);
        if crc32(&bytes[offset + 4..data_end]) != expected_crc {
            return false;
        }
        if chunk_type == b"IHDR" {
            if length != 13 || header {
                return false;
            }
            header = true;
        } else if chunk_type == b"IEND" {
            return header && length == 0 && chunk_end == bytes.len();
        }
        offset = chunk_end;
    }
    false
}
/// Sniff bytes instead of trusting the extension, and reject truncated known formats.
pub fn image_mime(bytes: &[u8]) -> Result<&'static str, StorageError> {
    if bytes.is_empty() || bytes.len() > MAX_IMAGE_BYTES {
        return Err(StorageError::LimitExceeded);
    }
    let mime = if valid_png(bytes) {
        "image/png"
    } else if bytes.starts_with(b"\xff\xd8\xff") && bytes.ends_with(b"\xff\xd9") {
        "image/jpeg"
    } else if (bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a"))
        && bytes.ends_with(b";")
    {
        "image/gif"
    } else if bytes.starts_with(b"RIFF")
        && bytes.get(8..12) == Some(b"WEBP")
        && bytes.len() >= 12
        && u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]) as usize + 8 <= bytes.len()
    {
        "image/webp"
    } else if bytes.starts_with(b"BM") && bytes.len() >= 26 {
        "image/bmp"
    } else if (bytes.starts_with(b"II*\0") || bytes.starts_with(b"MM\0*")) && bytes.len() >= 8 {
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
        (text.starts_with("<svg ")
            || text.starts_with("<svg>")
            || (text.starts_with("<?xml")
                && text
                    .as_bytes()
                    .windows(4)
                    .take(1024)
                    .any(|part| part == b"<svg")))
            && {
                let lowered = text.to_ascii_lowercase();
                lowered.contains("</svg>") || lowered.contains("/>")
            }
    }) {
        "image/svg+xml"
    } else {
        return Err(StorageError::UnsupportedFile);
    };
    Ok(mime)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_truncated_known_image_signatures() {
        assert_eq!(
            image_mime(b"\x89PNG\r\n\x1a\ntruncated"),
            Err(StorageError::UnsupportedFile)
        );
        assert_eq!(
            image_mime(b"GIF89a\x00\x00\x00"),
            Err(StorageError::UnsupportedFile)
        );
        assert_eq!(
            image_mime(b"<svg xmlns=\"http://www.w3.org/2000/svg\">").unwrap_err(),
            StorageError::UnsupportedFile
        );
    }
}
