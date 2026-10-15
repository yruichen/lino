use lino_application::navigation::NavigationPreferences;
use lino_runtime::DocumentRuntime;
use std::{fs, sync::atomic::AtomicBool};

#[test]
fn locations_favorites_order_and_removal_persist_without_touching_original_files() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("Notes");
    fs::create_dir(&root).unwrap();
    let file = root.join("Idea.md");
    fs::write(&file, "# Idea").unwrap();
    let store = dir.path().join("navigation.json");
    let runtime = DocumentRuntime::default();
    let initial = runtime.configure_navigation(&store, vec![]).unwrap();
    let mut values = NavigationPreferences::default();
    values.locations.push(root.to_string_lossy().into_owned());
    values.favorites.push(file.to_string_lossy().into_owned());
    values.sections.swap(0, 1);
    values.show_recents = true;
    let saved = runtime
        .update_navigation(initial.revision, values.clone())
        .unwrap();
    assert!(runtime
        .update_navigation(initial.revision, values.clone())
        .is_err());
    let reloaded = DocumentRuntime::default()
        .configure_navigation(&store, vec![])
        .unwrap();
    values.locations[0] = root.canonicalize().unwrap().to_string_lossy().into_owned();
    values.favorites[0] = file.canonicalize().unwrap().to_string_lossy().into_owned();
    assert_eq!(reloaded.values, values);
    values.locations.clear();
    runtime.update_navigation(saved.revision, values).unwrap();
    assert_eq!(fs::read_to_string(file).unwrap(), "# Idea");
}
#[test]
fn quick_open_searches_only_the_current_workspace_names_and_paths() {
    let dir = tempfile::tempdir().unwrap();
    let first = dir.path().join("Personal");
    let nested = first.join("Essays");
    let second = dir.path().join("Studio");
    fs::create_dir_all(&nested).unwrap();
    fs::create_dir(&second).unwrap();
    let exact = nested.join("Ideas.md");
    let prefix = second.join("Ideas old.md");
    fs::write(&exact, "# Ideas\n").unwrap();
    fs::write(&prefix, "# Archived\n").unwrap();
    fs::write(second.join("关于慢下来的思考.md"), "# Writing Principles\n").unwrap();
    let runtime = DocumentRuntime::default();
    let initial = runtime
        .configure_navigation(&dir.path().join("nav.json"), vec![])
        .unwrap();
    let values = NavigationPreferences {
        locations: vec![
            first.to_string_lossy().into_owned(),
            nested.to_string_lossy().into_owned(),
            second.to_string_lossy().into_owned(),
        ],
        ..Default::default()
    };
    runtime.update_navigation(initial.revision, values).unwrap();
    runtime.note_navigation_file(&prefix).unwrap();
    let token = AtomicBool::new(false);
    let found = runtime
        .quick_files("Ideas", Some(&first), None, &token)
        .unwrap();
    assert_eq!(found.files.len(), 1);
    assert_eq!(
        found.files[0].path,
        exact.canonicalize().unwrap().to_string_lossy()
    );
    assert_eq!(
        runtime
            .quick_files("principles", Some(&second), None, &token)
            .unwrap()
            .files
            .len(),
        0
    );
    assert_eq!(
        runtime
            .quick_files("慢思", Some(&second), None, &token)
            .unwrap()
            .files
            .len(),
        1
    );
    assert_eq!(
        runtime
            .quick_files("Ideas", Some(&nested), None, &token)
            .unwrap()
            .files
            .len(),
        1
    );
    assert!(runtime
        .quick_files("Ideas", Some(dir.path()), None, &token)
        .is_err());
    assert!(
        runtime
            .quick_files("Ideas", None, None, &AtomicBool::new(true))
            .unwrap()
            .cancelled
    );
    fs::write(second.join("Newest.md"), "# Newly arrived\n").unwrap();
    runtime.invalidate_navigation();
    assert_eq!(
        runtime
            .quick_files("Newest", Some(&second), None, &token)
            .unwrap()
            .files
            .len(),
        1
    );
}
#[test]
fn recent_results_exclude_current_and_corrupt_configuration_is_retained() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("Standalone.md");
    fs::write(&file, "# A").unwrap();
    let store = dir.path().join("nav.json");
    let runtime = DocumentRuntime::default();
    runtime.configure_navigation(&store, vec![]).unwrap();
    runtime.note_navigation_file(&file).unwrap();
    let token = AtomicBool::new(false);
    assert_eq!(
        runtime
            .quick_files("", None, None, &token)
            .unwrap()
            .files
            .len(),
        1
    );
    assert!(runtime
        .quick_files("", None, Some(file.to_str().unwrap()), &token)
        .unwrap()
        .files
        .is_empty());
    fs::write(&store, "broken config").unwrap();
    assert!(DocumentRuntime::default()
        .configure_navigation(&store, vec![])
        .is_err());
    assert_eq!(fs::read_to_string(store).unwrap(), "broken config");
}

#[test]
fn cross_location_drag_transfer_preserves_live_sources_and_never_overwrites_targets() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("Source");
    let destination = dir.path().join("Destination");
    fs::create_dir(&source).unwrap();
    fs::create_dir(&destination).unwrap();
    let file = source.join("note.md");
    fs::write(&file, "original").unwrap();
    let runtime = DocumentRuntime::default();
    let document = runtime.open_file(&file, None).unwrap();
    let workspace = lino_runtime::workspace::WorkspaceRuntime::open(&destination).unwrap();
    assert_eq!(
        workspace
            .transfer(&runtime, &file, "note.md", false)
            .unwrap_err()
            .code,
        lino_protocol::ErrorCode::Busy
    );
    workspace
        .transfer(&runtime, &file, "copy.md", true)
        .unwrap();
    assert_eq!(fs::read_to_string(&file).unwrap(), "original");
    assert!(workspace
        .transfer(&runtime, &file, "copy.md", true)
        .is_err());
    assert_eq!(
        fs::read_to_string(destination.join("copy.md")).unwrap(),
        "original"
    );
    runtime
        .abandon_document(&document.status.session_id)
        .unwrap();
    workspace
        .transfer(&runtime, &file, "moved.md", false)
        .unwrap();
    assert!(!file.exists());
    assert_eq!(
        fs::read_to_string(destination.join("moved.md")).unwrap(),
        "original"
    );
}

#[test]
fn unsupported_files_never_create_or_replace_a_document() {
    let dir = tempfile::tempdir().unwrap();
    let runtime = DocumentRuntime::default();
    let good = dir.path().join("note.md");
    fs::write(&good, "original").unwrap();
    let opened = runtime.open_file(&good, None).unwrap();
    for name in ["image.png", "archive.zip", "book.pdf", "page.html"] {
        let file = dir.path().join(name);
        fs::write(&file, "even valid utf8").unwrap();
        assert_eq!(
            runtime.validate_document_file(&file).unwrap_err().code,
            lino_protocol::ErrorCode::UnsupportedFile
        );
        assert_eq!(
            runtime.open_file(&file, None).unwrap_err().code,
            lino_protocol::ErrorCode::UnsupportedFile
        );
    }
    assert_eq!(
        runtime.file_session(&good).unwrap(),
        Some(opened.status.session_id)
    );
    assert_eq!(fs::read_to_string(&good).unwrap(), "original");
}

#[test]
fn quick_open_includes_native_media_without_admitting_binary_editing_sessions() {
    let dir = tempfile::tempdir().unwrap();
    for name in ["Figure.PNG", "Paper.pdf", "Notes.md", "Program.exe"] {
        fs::write(dir.path().join(name), b"binary fixture").unwrap();
    }
    let runtime = DocumentRuntime::default();
    let initial = runtime
        .configure_navigation(&dir.path().join("navigation.json"), vec![])
        .unwrap();
    runtime
        .update_navigation(
            initial.revision,
            NavigationPreferences {
                locations: vec![dir.path().to_string_lossy().into_owned()],
                ..Default::default()
            },
        )
        .unwrap();
    for query in ["Figure", "Paper", "Notes"] {
        let found = runtime
            .quick_files(query, Some(dir.path()), None, &AtomicBool::new(false))
            .unwrap();
        assert_eq!(found.files.len(), 1);
    }
    assert!(runtime
        .quick_files("Program", Some(dir.path()), None, &AtomicBool::new(false))
        .unwrap()
        .files
        .is_empty());
    for name in ["Figure.PNG", "Paper.pdf"] {
        assert!(runtime
            .validate_document_file(&dir.path().join(name))
            .is_err());
    }
}
