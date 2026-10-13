use serde::{Deserialize, Serialize};
use ts_rs::TS;
#[derive(Clone, Debug, Deserialize, Serialize, TS)]
pub struct ExportSource {
    pub job_id: String,
    pub session_id: String,
    pub revision: String,
    pub text: String,
    pub label: Option<String>,
    pub preferences: crate::EditorPreferences,
}
