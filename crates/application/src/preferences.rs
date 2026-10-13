//! Platform-independent effective editor preferences. No filesystem or wire types.

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Preferences {
    pub language: String,
    pub theme: String,
    pub auto_save: bool,
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
            auto_save: false,
            font_size: 16,
            line_height: 170,
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
