use crate::{
    dispatch::{error, number},
    DocumentRuntime,
};
use lino_adapters::settings::FileSettings;
use lino_application::preferences::{PreferenceState, Preferences};
use lino_protocol::{EditorPreferences, ErrorCode, PreferenceSnapshot, WireError};
use std::path::Path;

#[derive(Default)]
pub(crate) struct PreferenceRuntime {
    state: PreferenceState,
    store: Option<FileSettings>,
    storage_warning: Option<String>,
}
fn warning(durable: bool) -> Option<String> {
    (!durable).then(|| "directory_sync_unconfirmed".into())
}
fn effective(runtime: &PreferenceRuntime) -> PreferenceSnapshot {
    let mut value = snapshot(&runtime.state);
    value.storage_warning = runtime.storage_warning.clone();
    value
}
fn invalid(message: impl Into<String>) -> WireError {
    error(ErrorCode::InvalidMessage, &message.into(), false)
}
fn io(error: std::io::Error) -> WireError {
    crate::dispatch::error(ErrorCode::Io, &error.to_string(), true)
}
fn model(value: EditorPreferences) -> Preferences {
    Preferences {
        language: value.language,
        theme: value.theme,
        theme_family: value.theme_family,
        custom_themes: value.custom_themes.into_iter().map(theme_model).collect(),
        body_font: value.body_font,
        background_image: value.background_image,
        background_opacity: value.background_opacity,
        surface_opacity: value.surface_opacity,
        glass_style: value.glass_style,
        image_insertion: value.image_insertion,

        use_theme_font_size: value.use_theme_font_size,
        use_theme_line_height: value.use_theme_line_height,
        auto_save: value.auto_save,
        font_size: value.font_size,
        line_height: value.line_height,
        page_width: value.page_width,
        content_width: value.content_width,
        spell_check: value.spell_check,
        continue_lists: value.continue_lists,
        code_wrap: value.code_wrap,
        code_numbers: value.code_numbers,
    }
}
fn theme_model(value: lino_protocol::ThemeDefinition) -> lino_application::themes::ThemeDefinition {
    let variant = |v: lino_protocol::ThemeVariant| lino_application::themes::ThemeVariant {
        name: v.name,
        name_en: v.name_en,
        colors: v.colors,
    };
    lino_application::themes::ThemeDefinition {
        schema_version: value.schema_version,
        id: value.id,
        name: value.name,
        font_families: value.font_families,
        font_size: value.font_size,
        line_height: value.line_height,
        reading_width: value.reading_width,
        light: variant(value.light),
        dark: variant(value.dark),
    }
}
fn theme_wire(value: &lino_application::themes::ThemeDefinition) -> lino_protocol::ThemeDefinition {
    let variant = |v: &lino_application::themes::ThemeVariant| lino_protocol::ThemeVariant {
        name: v.name.clone(),
        name_en: v.name_en.clone(),
        colors: v.colors.clone(),
    };
    lino_protocol::ThemeDefinition {
        schema_version: value.schema_version,
        id: value.id.clone(),
        name: value.name.clone(),
        font_families: value.font_families.clone(),
        font_size: value.font_size,
        line_height: value.line_height,
        reading_width: value.reading_width,
        light: variant(&value.light),
        dark: variant(&value.dark),
    }
}
fn snapshot(state: &PreferenceState) -> PreferenceSnapshot {
    let value = &state.values;
    PreferenceSnapshot {
        storage_warning: None,
        schema_version: 1,
        revision: state.revision.to_string(),
        values: EditorPreferences {
            language: value.language.clone(),
            theme: value.theme.clone(),
            theme_family: value.theme_family.clone(),
            custom_themes: value.custom_themes.iter().map(theme_wire).collect(),
            body_font: value.body_font.clone(),
            background_image: value.background_image.clone(),
            background_opacity: value.background_opacity,
            surface_opacity: value.surface_opacity,
            glass_style: value.glass_style.clone(),
            image_insertion: value.image_insertion.clone(),

            use_theme_font_size: value.use_theme_font_size,
            use_theme_line_height: value.use_theme_line_height,
            auto_save: value.auto_save,
            font_size: value.font_size,
            line_height: value.line_height,
            page_width: value.page_width,
            content_width: value.content_width.clone(),
            spell_check: value.spell_check,
            continue_lists: value.continue_lists,
            code_wrap: value.code_wrap,
            code_numbers: value.code_numbers,
        },
    }
}
fn bytes(state: &PreferenceState) -> Result<Vec<u8>, WireError> {
    serde_json::to_vec_pretty(&snapshot(state)).map_err(|e| invalid(e.to_string()))
}
impl DocumentRuntime {
    pub fn configure_preferences(
        &self,
        path: &Path,
        legacy_language: Option<String>,
        legacy_autosave: Option<bool>,
    ) -> Result<PreferenceSnapshot, WireError> {
        let mut runtime = self
            .preferences
            .lock()
            .map_err(|_| invalid("Preferences lock poisoned"))?;
        if runtime.store.is_some() {
            return Ok(effective(&runtime));
        }
        let store = FileSettings::new(path);
        let state = if let Some(bytes) = store.load().map_err(io)? {
            let saved: PreferenceSnapshot = serde_json::from_slice(&bytes)
                .map_err(|e| invalid(format!("Cannot read preferences: {e}")))?;
            if saved.schema_version != 1 {
                return Err(invalid(
                    "Unsupported preferences schema; original file retained",
                ));
            }
            let values = model(saved.values);
            values.validate().map_err(invalid)?;
            PreferenceState {
                revision: number(&saved.revision)?,
                values,
            }
        } else {
            let mut state = PreferenceState::default();
            if let Some(language) = legacy_language {
                state.values.language = language;
            }
            if let Some(autosave) = legacy_autosave {
                state.values.auto_save = autosave;
            }
            state.values.validate().map_err(invalid)?;
            runtime.storage_warning = warning(store.save(&bytes(&state)?).map_err(io)?);
            state
        };
        runtime.state = state;
        runtime.store = Some(store);
        Ok(effective(&runtime))
    }
    pub fn preferences(&self) -> Result<PreferenceSnapshot, WireError> {
        let runtime = self
            .preferences
            .lock()
            .map_err(|_| invalid("Preferences lock poisoned"))?;
        Ok(effective(&runtime))
    }
    pub fn update_preferences(
        &self,
        expected_revision: &str,
        values: EditorPreferences,
    ) -> Result<PreferenceSnapshot, WireError> {
        let mut runtime = self
            .preferences
            .lock()
            .map_err(|_| invalid("Preferences lock poisoned"))?;
        let next = runtime
            .state
            .replacement(number(expected_revision)?, model(values))
            .map_err(invalid)?;
        let store = runtime
            .store
            .as_ref()
            .ok_or_else(|| invalid("Preferences storage is not configured"))?;
        let durable = store.save(&bytes(&next)?).map_err(io)?;
        runtime.state = next;
        runtime.storage_warning = warning(durable);
        Ok(effective(&runtime))
    }
}
