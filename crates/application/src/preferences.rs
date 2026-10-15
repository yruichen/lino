//! Platform-independent effective editor preferences. No filesystem or wire types.

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Preferences {
    pub language: String,
    pub theme: String,
    pub theme_family: String,
    pub custom_themes: Vec<crate::themes::ThemeDefinition>,
    pub body_font: String,
    pub background_image: String,
    pub background_opacity: u32,
    pub surface_opacity: u32,
    pub glass_style: String,
    pub image_insertion: String,
    pub use_theme_font_size: bool,
    pub use_theme_line_height: bool,
    pub auto_save: bool,
    pub automatic_update_checks: bool,
    pub include_prerelease_updates: bool,
    pub font_size: u32,
    pub line_height: u32,
    pub page_width: u32,
    pub content_width: String,
    pub spell_check: bool,
    pub continue_lists: bool,
    pub code_wrap: bool,
    pub code_numbers: bool,
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            language: "system".into(),
            theme: "system".into(),
            theme_family: "paper".into(),
            custom_themes: Vec::new(),
            body_font: String::new(),
            background_image: String::new(),
            background_opacity: 20,
            surface_opacity: 100,
            glass_style: "solid".into(),
            image_insertion: "reference".into(),
            use_theme_font_size: true,
            use_theme_line_height: true,
            auto_save: false,
            automatic_update_checks: false,
            include_prerelease_updates: true,
            font_size: 17,
            line_height: 176,
            page_width: 820,
            content_width: "adaptive".into(),
            spell_check: false,
            continue_lists: true,
            code_wrap: true,
            code_numbers: false,
        }
    }
}
impl Preferences {
    pub fn validate(&self) -> Result<(), &'static str> {
        if !["system", "en", "zh-Hans"].contains(&self.language.as_str()) {
            return Err("Unsupported interface language");
        }
        if !["system", "light", "dark"].contains(&self.theme.as_str()) {
            return Err("Unsupported appearance");
        }
        for (index, theme) in self.custom_themes.iter().enumerate() {
            theme.validate()?;
            if self.custom_themes[..index].iter().any(|t| t.id == theme.id) {
                return Err("Duplicate custom theme identifier");
            }
        }
        if !crate::themes::BUILTIN_FAMILIES.contains(&self.theme_family.as_str())
            && !self.custom_themes.iter().any(|t| t.id == self.theme_family)
        {
            return Err("Selected theme is unavailable");
        }
        if self.background_opacity > 100
            || self.surface_opacity > 100
            || !["solid", "regular", "clear"].contains(&self.glass_style.as_str())
            || !["reference", "copy"].contains(&self.image_insertion.as_str())
            || self.background_image.chars().any(char::is_control)
        {
            return Err("Invalid appearance or image insertion preference");
        }
        if self.body_font.chars().any(char::is_control) {
            return Err("Invalid body font name");
        }
        if !["adaptive", "fixed"].contains(&self.content_width.as_str()) {
            return Err("Unsupported content width mode");
        }
        // Product control ranges, not claims about Typora's limits.
        if !(10..=40).contains(&self.font_size)
            || !(100..=240).contains(&self.line_height)
            || !(400..=2000).contains(&self.page_width)
        {
            return Err("Editor layout preference is outside the supported range");
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Default)]
pub struct PreferenceState {
    pub revision: u64,
    pub values: Preferences,
}
impl PreferenceState {
    pub fn replacement(&self, expected: u64, values: Preferences) -> Result<Self, &'static str> {
        if self.revision != expected {
            return Err("Preferences changed; reload before applying");
        }
        values.validate()?;
        Ok(Self {
            revision: self
                .revision
                .checked_add(1)
                .ok_or("Preference revision exhausted")?,
            values,
        })
    }
}
