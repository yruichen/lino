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
