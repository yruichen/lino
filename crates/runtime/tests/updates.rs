use lino_runtime::DocumentRuntime;

#[test]
fn public_releases_are_compared_safely_and_preferences_survive_reopening() {
    let runtime = DocumentRuntime::default();
    let data = r#"[{"tag_name":"v0.0.10","prerelease":true,"draft":false,"html_url":"https://untrusted.invalid/"},{"tag_name":"v0.0.9","prerelease":false,"draft":false}]"#;
    let beta = runtime.evaluate_releases(data, "0.0.9", true).unwrap();
    assert!(beta.newer);
    assert_eq!(
        beta.release.unwrap().url,
        "https://github.com/yruichen/lino/releases/tag/v0.0.10"
    );
    assert!(
        !runtime
            .evaluate_releases(data, "0.0.9", false)
            .unwrap()
            .newer
    );
    assert!(runtime
        .evaluate_releases("not json", "0.0.9", true)
        .is_err());
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("settings.json");
    let initial = runtime.configure_preferences(&path, None, None).unwrap();
    let mut old = serde_json::to_value(initial).unwrap();
    for key in ["automatic_update_checks", "include_prerelease_updates"] {
        old["values"].as_object_mut().unwrap().remove(key);
    }
    std::fs::write(&path, serde_json::to_vec(&old).unwrap()).unwrap();
    let restored = DocumentRuntime::default();
    let initial = restored.configure_preferences(&path, None, None).unwrap();
    assert!(!initial.values.automatic_update_checks);
    assert!(initial.values.include_prerelease_updates);
    let mut values = initial.values;
    values.automatic_update_checks = true;
    values.include_prerelease_updates = false;
    restored
        .update_preferences(&initial.revision, values)
        .unwrap();
    let reopened = DocumentRuntime::default()
        .configure_preferences(&path, None, None)
        .unwrap();
    assert!(reopened.values.automatic_update_checks);
    assert!(!reopened.values.include_prerelease_updates);
}
