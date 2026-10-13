use crate::{changes::validate_boundary, ModelError};

pub fn utf16_to_utf8(text: &str, position: usize) -> Result<usize, ModelError> {
    let mut units = 0;
    for (offset, character) in text.char_indices() {
        if units == position {
            validate_boundary(text, offset)?;
            return Ok(offset);
        }
        units += character.len_utf16();
        if units > position {
            return Err(ModelError::InvalidUnicodeBoundary);
        }
    }
    if units == position {
        Ok(text.len())
    } else {
        Err(ModelError::InvalidRange)
    }
}

pub fn utf8_to_utf16(text: &str, position: usize) -> Result<usize, ModelError> {
    if position > text.len() {
        return Err(ModelError::InvalidRange);
    }
    validate_boundary(text, position)?;
    Ok(text[..position].encode_utf16().count())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn coordinates_reject_surrogate_and_crlf_splits() {
        let text = "中👩🏽‍💻\r\n末";
        for (offset, _) in text.char_indices() {
            if validate_boundary(text, offset).is_ok() {
                assert_eq!(
                    utf16_to_utf8(text, utf8_to_utf16(text, offset).unwrap()).unwrap(),
                    offset
                );
            }
        }
        assert_eq!(
            utf16_to_utf8(text, 2),
            Err(ModelError::InvalidUnicodeBoundary)
        );
        assert_eq!(
            utf8_to_utf16(text, text.find('\n').unwrap()),
            Err(ModelError::SplitCrLf)
        );
    }
}
