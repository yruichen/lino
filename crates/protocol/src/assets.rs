use serde::{Deserialize, Serialize};
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SaveImagesRequest {
    pub ticket_id: String,
    pub target: crate::SaveTarget,
    pub sources: Vec<String>,
}
