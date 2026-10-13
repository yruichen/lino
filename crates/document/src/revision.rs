use crate::ModelError;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Ord, PartialOrd)]
pub struct Revision(u64);

impl Revision {
    pub const fn initial() -> Self {
        Self(0)
    }
    pub const fn value(self) -> u64 {
        self.0
    }
    pub fn next(self) -> Result<Self, ModelError> {
        self.0
            .checked_add(1)
            .map(Self)
            .ok_or(ModelError::RevisionExhausted)
    }
}
