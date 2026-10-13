use crate::{changes::validate_boundary, ModelError, Revision, TextChange, MAX_DOCUMENT_BYTES};
use std::sync::Arc;

#[derive(Clone, Debug)]
pub struct Snapshot {
    revision: Revision,
    text: Arc<str>,
}

impl Snapshot {
    pub fn new(text: String) -> Result<Self, ModelError> {
        if text.len() > MAX_DOCUMENT_BYTES {
            return Err(ModelError::LimitExceeded);
        }
        Ok(Self {
            revision: Revision::initial(),
            text: text.into(),
        })
    }
    pub fn revision(&self) -> Revision {
        self.revision
    }
    pub fn text(&self) -> &str {
        &self.text
    }
    pub fn apply(&self, changes: &[TextChange]) -> Result<Self, ModelError> {
        let mut previous_end = 0;
        let mut removed = 0usize;
        let mut inserted = 0usize;
        for change in changes {
            if change.from > change.to || change.to > self.text.len() {
                return Err(ModelError::InvalidRange);
            }
            if change.from < previous_end {
                return Err(ModelError::OverlappingChanges);
            }
            validate_boundary(&self.text, change.from)?;
            validate_boundary(&self.text, change.to)?;
            removed = removed
                .checked_add(change.to - change.from)
                .ok_or(ModelError::LimitExceeded)?;
            inserted = inserted
                .checked_add(change.insert.len())
                .ok_or(ModelError::LimitExceeded)?;
            previous_end = change.to;
        }
        let length = self
            .text
            .len()
            .checked_sub(removed)
            .and_then(|n| n.checked_add(inserted))
            .filter(|n| *n <= MAX_DOCUMENT_BYTES)
            .ok_or(ModelError::LimitExceeded)?;
        let mut text = String::with_capacity(length);
        let mut cursor = 0;
        for change in changes {
            text.push_str(&self.text[cursor..change.from]);
            text.push_str(&change.insert);
            cursor = change.to;
        }
        text.push_str(&self.text[cursor..]);
        if text == self.text.as_ref() {
            return Ok(self.clone());
        }
        Ok(Self {
            revision: self.revision.next()?,
            text: text.into(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn changes_are_atomic_and_never_split_utf8_or_crlf() {
        let original = Snapshot::new("中\r\n👩尾".into()).unwrap();
        assert_eq!(
            original
                .apply(&[TextChange {
                    from: 1,
                    to: 3,
                    insert: "x".into()
                }])
                .unwrap_err(),
            ModelError::InvalidUnicodeBoundary
        );
        assert_eq!(
            original
                .apply(&[TextChange {
                    from: 4,
                    to: 4,
                    insert: "x".into()
                }])
                .unwrap_err(),
            ModelError::SplitCrLf
        );
        let edited = original
            .apply(&[TextChange {
                from: 5,
                to: 9,
                insert: "🙂".into(),
            }])
            .unwrap();
        assert_eq!(original.text(), "中\r\n👩尾");
        assert_eq!(edited.text(), "中\r\n🙂尾");
        assert_eq!(edited.revision().value(), 1);
        assert_eq!(edited.apply(&[]).unwrap().revision(), edited.revision());
    }
}
