//! Theme values are data, never executable CSS. Hosts project the same palette.
use std::collections::BTreeMap;

pub const BUILTIN_FAMILIES: [&str; 6] = ["paper", "book", "mist", "grove", "slate", "type"];
pub const COLOR_ROLES: [&str; 19] = [
    "bg",
    "sidebar",
    "surface",
    "code",
    "text",
    "muted",
    "heading",
    "accent",
    "link",
    "quote",
    "border",
    "selection",
    "sidebarActive",
    "keyword",
    "string",
    "number",
    "error",
    "match",
    "focus",
];

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ThemeVariant {
    pub name: String,
    pub name_en: String,
    pub colors: BTreeMap<String, String>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
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
impl ThemeDefinition {
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.schema_version != 1
            || !self.id.starts_with("custom-")
            || self.id.len() == 7
            || !self
                .id
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'-')
        {
            return Err("Theme needs a unique custom- identifier and schema version 1");
        }
        if self.name.trim().is_empty()
            || self.font_families.is_empty()
            || self
                .font_families
                .iter()
                .any(|f| f.trim().is_empty() || f.chars().any(char::is_control))
        {
            return Err("Theme needs a name and font family");
        }
        if !(10..=40).contains(&self.font_size)
            || !(100..=240).contains(&self.line_height)
            || !(400..=2000).contains(&self.reading_width)
        {
            return Err("Theme typography is outside the supported range");
        }
        for variant in [&self.light, &self.dark] {
            if variant.name.trim().is_empty()
                || variant.name_en.trim().is_empty()
                || variant.colors.len() != COLOR_ROLES.len()
                || COLOR_ROLES
                    .iter()
                    .any(|role| !variant.colors.contains_key(*role))
                || variant.colors.values().any(|c| {
                    c.len() != 7
                        || !c.starts_with('#')
                        || !c[1..].bytes().all(|v| v.is_ascii_hexdigit())
                })
            {
                return Err("Both theme appearances need all 19 colors in #RRGGBB format");
            }
        }
        Ok(())
    }
}
