use lino_runtime::DocumentRuntime;
use std::fs;

#[test]
fn old_width_settings_gain_adaptive_mode_without_losing_the_saved_numeric_width() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("settings.json");
    let runtime = DocumentRuntime::default();
    let initial = runtime.configure_preferences(&path, None, None).unwrap();
    let mut old = serde_json::to_value(initial).unwrap();
    old["values"]["page_width"] = 1040.into();
    old["values"]
        .as_object_mut()
        .unwrap()
        .remove("content_width");
    fs::write(&path, serde_json::to_vec(&old).unwrap()).unwrap();
    let restored = DocumentRuntime::default();
    let current = restored.configure_preferences(&path, None, None).unwrap();
    assert_eq!(current.values.content_width, "adaptive");
    assert_eq!(current.values.page_width, 1040);
    let mut fixed = current.values;
    fixed.content_width = "fixed".into();
    let accepted = restored
        .update_preferences(&current.revision, fixed)
        .unwrap();
    let bytes = fs::read(&path).unwrap();
    let mut invalid = accepted.values;
    invalid.content_width = "unknown".into();
    assert!(restored
        .update_preferences(&accepted.revision, invalid)
        .is_err());
    assert_eq!(fs::read(&path).unwrap(), bytes);
    let loaded = DocumentRuntime::default()
        .configure_preferences(&path, None, None)
        .unwrap();
    assert_eq!(loaded.values.content_width, "fixed");
    assert_eq!(loaded.values.page_width, 1040);
}

#[test]
fn preferences_migrate_once_persist_and_reject_stale_or_invalid_changes() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("settings.json");
    let runtime = DocumentRuntime::default();
    let first = runtime
        .configure_preferences(&path, Some("zh-Hans".into()), Some(true))
        .unwrap();
    assert_eq!(first.values.language, "zh-Hans");
    assert!(first.values.auto_save);
    let mut values = first.values.clone();
    values.theme = "dark".into();
    values.font_size = 20;
    let next = runtime
        .update_preferences(&first.revision, values.clone())
        .unwrap();
    assert_eq!(next.revision, "1");
    assert!(runtime
        .update_preferences(&first.revision, values.clone())
        .is_err());
    let bytes = fs::read(&path).unwrap();
    values.font_size = 0;
    assert!(runtime.update_preferences(&next.revision, values).is_err());
    assert_eq!(fs::read(&path).unwrap(), bytes);
    let restored = DocumentRuntime::default()
        .configure_preferences(&path, Some("en".into()), Some(false))
        .unwrap();
    assert_eq!(restored.revision, next.revision);
    assert_eq!(restored.values.theme, "dark");
    assert_eq!(restored.values.language, "zh-Hans");
    assert!(restored.values.auto_save);
}

#[test]
fn settings_io_and_future_schema_failures_preserve_previous_file_and_effective_values() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("settings.json");
    fs::write(&path, b"{\"schema_version\":99}").unwrap();
    let runtime = DocumentRuntime::default();
    assert!(runtime.configure_preferences(&path, None, None).is_err());
    assert_eq!(fs::read(&path).unwrap(), b"{\"schema_version\":99}");
    let current = runtime.preferences().unwrap();
    assert!(runtime
        .update_preferences(&current.revision, current.values)
        .is_err());
    fs::remove_file(&path).unwrap();
    let first = runtime.configure_preferences(&path, None, None).unwrap();
    fs::remove_file(&path).unwrap();
    fs::create_dir(&path).unwrap();
    let mut values = first.values;
    values.auto_save = true;
    assert!(runtime.update_preferences(&first.revision, values).is_err());
    assert!(!runtime.preferences().unwrap().values.auto_save);
}

#[test]
fn theme_import_roundtrips_and_rejects_bad_data_without_touching_the_saved_preferences() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("settings.json");
    let runtime = DocumentRuntime::default();
    let first = runtime.configure_preferences(&path, None, None).unwrap();
    let catalog: Vec<lino_protocol::ThemeDefinition> =
        serde_json::from_str(include_str!("../../../assets/themes/classic.json")).unwrap();
    let mut custom = catalog[0].clone();
    custom.id = "custom-writing".into();
    custom.name = "My Writing".into();
    // DIY contrast choices are not blocked; only the data format is validated.
    custom
        .dark
        .colors
        .insert("text".into(), custom.dark.colors["bg"].clone());
    let mut values = first.values;
    values.custom_themes.push(custom);
    values.theme_family = "custom-writing".into();
    values.body_font = "Georgia".into();
    values.font_size = 23;
    values.use_theme_font_size = false;
    let saved = runtime.update_preferences(&first.revision, values).unwrap();
    let restored = DocumentRuntime::default()
        .configure_preferences(&path, None, None)
        .unwrap();
    assert_eq!(
        restored.values.custom_themes[0].dark.colors,
        saved.values.custom_themes[0].dark.colors
    );
    assert_eq!(restored.values.theme_family, "custom-writing");
    assert_eq!(restored.values.body_font, "Georgia");
    assert_eq!(restored.values.font_size, 23);
    assert!(!restored.values.use_theme_font_size);
    let bytes = fs::read(&path).unwrap();
    let mut invalid = saved.values;
    invalid.custom_themes[0]
        .light
        .colors
        .insert("bg".into(), "url(https://example.invalid)".into());
    assert!(runtime
        .update_preferences(&saved.revision, invalid)
        .is_err());
    assert_eq!(fs::read(&path).unwrap(), bytes);
}

#[test]
fn appearance_and_image_insertion_settings_roundtrip_and_older_files_get_defaults() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("settings.json");
    let runtime = DocumentRuntime::default();
    let first = runtime.configure_preferences(&path, None, None).unwrap();
    let mut values = first.values;
    values.background_image = "platform-bookmark".into();
    values.background_opacity = 15;
    values.surface_opacity = 45;
    values.glass_style = "clear".into();
    values.image_insertion = "copy".into();
    let saved = runtime.update_preferences(&first.revision, values).unwrap();
    let restored = DocumentRuntime::default()
        .configure_preferences(&path, None, None)
        .unwrap();
    assert_eq!(
        restored.values.background_image,
        saved.values.background_image
    );
    assert_eq!(restored.values.background_opacity, 15);
    assert_eq!(restored.values.surface_opacity, 45);
    assert_eq!(restored.values.glass_style, "clear");
    assert_eq!(restored.values.image_insertion, "copy");
    let mut legacy: serde_json::Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    for key in [
        "background_image",
        "background_opacity",
        "surface_opacity",
        "glass_style",
        "image_insertion",
    ] {
        legacy["values"].as_object_mut().unwrap().remove(key);
    }
    fs::write(&path, serde_json::to_vec(&legacy).unwrap()).unwrap();
    let old = DocumentRuntime::default()
        .configure_preferences(&path, None, None)
        .unwrap();
    assert_eq!(old.values.background_image, "");
    assert_eq!(old.values.background_opacity, 20);
    assert_eq!(old.values.surface_opacity, 100);
    assert_eq!(old.values.glass_style, "solid");
    assert_eq!(old.values.image_insertion, "reference");
    let mut invalid = saved.values;
    invalid.background_opacity = 101;
    assert!(runtime
        .update_preferences(&saved.revision, invalid)
        .is_err());
}

#[test]
fn older_preferences_keep_the_users_typography_when_the_theme_fields_are_missing() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("settings.json");
    let initial = DocumentRuntime::default()
        .configure_preferences(&path, None, None)
        .unwrap();
    let mut old = serde_json::to_value(initial).unwrap();
    let values = old["values"].as_object_mut().unwrap();
    for key in [
        "theme_family",
        "custom_themes",
        "body_font",
        "use_theme_font_size",
        "use_theme_line_height",
    ] {
        values.remove(key);
    }
    values.insert("font_size".into(), 21.into());
    values.insert("line_height".into(), 195.into());
    fs::write(&path, serde_json::to_vec(&old).unwrap()).unwrap();
    let loaded = DocumentRuntime::default()
        .configure_preferences(&path, None, None)
        .unwrap();
    assert_eq!(loaded.values.theme_family, "paper");
    assert_eq!(loaded.values.font_size, 21);
    assert_eq!(loaded.values.line_height, 195);
    assert!(!loaded.values.use_theme_font_size);
    assert!(!loaded.values.use_theme_line_height);
}
