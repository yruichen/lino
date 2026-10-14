use serde::{Deserialize, Serialize};
use ts_rs::TS;

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(deny_unknown_fields)]
pub struct ThemeVariant {
    pub name: String,
    pub name_en: String,
    pub colors: std::collections::BTreeMap<String, String>,
}
#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(deny_unknown_fields)]
pub struct ThemeDefinition {
    pub schema_version: u32,
    pub id: String,
    pub name: String,
    pub font_families: Vec<String>,
    pub font_size: u32,
    pub line_height: u32,
    pub reading_width: u32,
    pub light: ThemeVariant,
    pub dark: ThemeVariant,
}

#[derive(Clone, Debug, Deserialize, Serialize, TS)]
#[serde(deny_unknown_fields)]
pub struct EditorPreferences {
    pub language: String,
    pub theme: String,
    #[serde(default = "paper_family")]
    pub theme_family: String,
    #[serde(default)]
    pub custom_themes: Vec<ThemeDefinition>,
    #[serde(default)]
    pub body_font: String,
    /// Platform bookmark interpreted only by the native appearance adapter.
    #[serde(default)]
    pub background_image: String,
    #[serde(default = "background_opacity")]
    pub background_opacity: u32,
    #[serde(default = "surface_opacity")]
    pub surface_opacity: u32,
    #[serde(default = "solid_glass")]
    pub glass_style: String,
    #[serde(default = "reference_image")]
    pub image_insertion: String,
    // Missing flags keep the typography explicitly chosen in older settings.
    #[serde(default)]
    pub use_theme_font_size: bool,
    #[serde(default)]
    pub use_theme_line_height: bool,
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
fn paper_family() -> String {
    "paper".into()
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

fn background_opacity() -> u32 {
    20
}
fn surface_opacity() -> u32 {
    100
}
fn solid_glass() -> String {
    "solid".into()
}
fn reference_image() -> String {
    "reference".into()
}
