use serde::{Deserialize, Serialize};
use ts_rs::TS;

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
pub struct UpdateRelease {
    pub version: String,
    pub url: String,
    pub prerelease: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
pub struct UpdateCheck {
    pub newer: bool,
    pub release: Option<UpdateRelease>,
}
