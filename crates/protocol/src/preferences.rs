use serde::{Deserialize, Serialize};
use ts_rs::TS;

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(deny_unknown_fields)]
pub struct EditorPreferences {
    pub language: String,
    pub theme: String,
    pub auto_save: bool,
    pub font_size: u32,
    /// Percentage, so configuration has no floating-point rounding ambiguity.
    pub line_height: u32,
    pub page_width: u32,
    /// Older settings retain their numeric width; adaptive is the new default.
    #[serde(default = "adaptive_width")]
    pub content_width: String,
    pub spell_check: bool,
    pub continue_lists: bool,
    pub code_wrap: bool,
    pub code_numbers: bool,
}
fn adaptive_width() -> String {
    "adaptive".into()
}
#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(deny_unknown_fields)]
pub struct PreferenceSnapshot {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub storage_warning: Option<String>,
    pub schema_version: u32,
    pub revision: String,
    pub values: EditorPreferences,
}
