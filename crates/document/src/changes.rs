use std::fmt;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TextChange {
    pub from: usize,
    pub to: usize,
    pub insert: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ModelError {
    InvalidRange,
    OverlappingChanges,
    InvalidUnicodeBoundary,
    SplitCrLf,
    LimitExceeded,
    RevisionExhausted,
}

impl fmt::Display for ModelError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{self:?}")
    }
}
impl std::error::Error for ModelError {}

pub(crate) fn validate_boundary(text: &str, position: usize) -> Result<(), ModelError> {
    if !text.is_char_boundary(position) {
        return Err(ModelError::InvalidUnicodeBoundary);
    }
    if position > 0
        && position < text.len()
        && text.as_bytes()[position - 1] == b'\r'
        && text.as_bytes()[position] == b'\n'
    {
        return Err(ModelError::SplitCrLf);
    }
    Ok(())
}
