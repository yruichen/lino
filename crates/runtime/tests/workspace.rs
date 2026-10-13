use lino_adapters::workspace::FileWorkspace;
use lino_application::ports::StorageError;
use lino_application::workspace::WorkspacePort;
use lino_protocol::{
    ErrorCode, Request, RequestEnvelope, Response, ResponseEnvelope, PROTOCOL_VERSION,
};
use lino_runtime::{
    workspace::{Mutation, SearchOptions, WorkspaceRuntime},
    DocumentRuntime,
};
use std::{fs, sync::Arc, time::Duration};

fn options(text: &str, content: bool) -> SearchOptions {
    SearchOptions {
        text: text.into(),
        content,
        case_sensitive: false,
        regex: false,
        whole_word: false,
        include_hidden: false,
    }
}
fn call(runtime: &DocumentRuntime, operation: Request) -> Response {
    let request = serde_json::to_string(&RequestEnvelope {
        protocol_version: PROTOCOL_VERSION,
        request_id: "fixture".into(),
        operation,
    })
    .unwrap();
    serde_json::from_str::<ResponseEnvelope>(&runtime.dispatch(&request).unwrap())
        .unwrap()
        .result
}

#[test]
fn lazy_listing_and_path_validation_stay_inside_the_granted_root() {
    let dir = tempfile::tempdir().unwrap();
    fs::create_dir(dir.path().join("notes")).unwrap();
    fs::write(dir.path().join("z.md"), "hello").unwrap();
    fs::write(dir.path().join(".hidden.md"), "private").unwrap();
    let workspace = FileWorkspace::open(dir.path()).unwrap();
    let list = workspace.list("", false).unwrap();
    assert_eq!(
        list.entries
            .iter()
            .map(|e| e.name.as_str())
            .collect::<Vec<_>>(),
        ["notes", "z.md"]
    );
    assert_eq!(workspace.list("", true).unwrap().entries.len(), 3);
    assert!(matches!(
        workspace.resolve("../escape", true),
        Err(StorageError::Denied)
    ));
    assert!(matches!(
        workspace.resolve(dir.path().to_str().unwrap(), false),
        Err(StorageError::Denied)
    ));
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(dir.path().join("notes"), dir.path().join("alias")).unwrap();
        assert!(matches!(
            workspace.resolve("alias/file.md", true),
            Err(StorageError::UnsupportedFile)
        ));
    }
}
#[test]
fn file_and_directory_mutations_publish_complete_copies_and_never_overwrite_targets() {
    let dir = tempfile::tempdir().unwrap();
    fs::create_dir(dir.path().join("notes")).unwrap();
    fs::write(dir.path().join("notes/source.md"), "中文\r\nline\n").unwrap();
    let runtime = DocumentRuntime::default();
    let workspace = WorkspaceRuntime::open(dir.path()).unwrap();
    workspace
        .mutate(&runtime, Mutation::NewFile, "", "new.md")
        .unwrap();
    workspace
        .mutate(&runtime, Mutation::NewDirectory, "", "folder")
        .unwrap();
    workspace
        .mutate(&runtime, Mutation::Copy, "notes", "copied")
        .unwrap();
    assert_eq!(
        fs::read(dir.path().join("copied/source.md")).unwrap(),
        fs::read(dir.path().join("notes/source.md")).unwrap()
    );
    workspace
        .mutate(&runtime, Mutation::Move, "copied", "renamed")
        .unwrap();
    assert!(!dir.path().join("copied").exists());
    let conflict = workspace
        .mutate(
            &runtime,
            Mutation::Move,
            "notes/source.md",
            "renamed/source.md",
        )
        .unwrap_err();
    assert_eq!(conflict.code, ErrorCode::ChangedExternally);
    assert!(dir.path().join("notes/source.md").exists());
    assert!(workspace
        .mutate(&runtime, Mutation::Copy, "notes", "notes/recursive")
        .is_err());
    assert!(workspace
        .mutate(&runtime, Mutation::Move, "", "moved-root")
        .is_err());
}
#[test]
fn incomplete_directory_copy_removes_only_its_staging_output() {
    let dir = tempfile::tempdir().unwrap();
    fs::create_dir(dir.path().join("source")).unwrap();
    fs::write(dir.path().join("source/valid.md"), "retained").unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(
        dir.path().join("source/valid.md"),
        dir.path().join("source/link"),
    )
    .unwrap();
    #[cfg(not(unix))]
    fs::File::create(dir.path().join("source/huge.md"))
        .unwrap()
        .set_len(65 * 1024 * 1024)
        .unwrap();
    let workspace = WorkspaceRuntime::open(dir.path()).unwrap();
    assert!(workspace
        .mutate(
            &DocumentRuntime::default(),
            Mutation::Copy,
            "source",
            "copy"
        )
        .is_err());
    assert!(!dir.path().join("copy").exists());
    assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 1);
    assert_eq!(
        fs::read_to_string(dir.path().join("source/valid.md")).unwrap(),
        "retained"
    );
}
#[test]
fn queries_honor_unicode_regex_case_whole_word_and_cancel_before_or_after_dispatch() {
    let dir = tempfile::tempdir().unwrap();
    fs::create_dir(dir.path().join("nested")).unwrap();
    fs::write(
        dir.path().join("nested/中文.md"),
        "\u{feff}Hello helper\r\n你好\rHELLO\n",
    )
    .unwrap();
    fs::write(dir.path().join("binary"), [0, 255]).unwrap();
    let workspace = WorkspaceRuntime::open(dir.path()).unwrap();
    let names = workspace.search(1, options("中文", false)).unwrap();
    assert_eq!(names.hits[0].path, "nested/中文.md");
    let mut query = options("hello", true);
    query.whole_word = true;
    let results = workspace.search(2, query.clone()).unwrap();
    assert_eq!(
        results.hits.iter().map(|h| h.line).collect::<Vec<_>>(),
        [1, 3]
    );
    assert_eq!(results.skipped, 1);
    query.case_sensitive = true;
    assert!(workspace.search(3, query).unwrap().hits.is_empty());
    let mut regex = options("^你.+$", true);
    regex.regex = true;
    assert_eq!(workspace.search(4, regex).unwrap().hits[0].line, 2);
    let mut invalid = options("[", true);
    invalid.regex = true;
    assert!(workspace.search(5, invalid).is_err());
    workspace.cancel(6);
    assert!(
        workspace
            .search(6, options("hello", true))
            .unwrap()
            .cancelled
    );
    assert!(
        !workspace
            .search(8, options("hello", true))
            .unwrap()
            .cancelled
    );
    assert!(
        workspace
            .search(7, options("hello", true))
            .unwrap()
            .cancelled
    );
}
#[test]
fn active_document_and_save_target_reservations_block_rename_without_data_loss() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("note.md"), "original").unwrap();
    let runtime = DocumentRuntime::default();
    let opened = runtime
        .open_file(&dir.path().join("note.md"), None)
        .unwrap();
    let workspace = WorkspaceRuntime::open(dir.path()).unwrap();
    assert_eq!(
        workspace
            .mutate(&runtime, Mutation::Move, "note.md", "new.md")
            .unwrap_err()
            .code,
        ErrorCode::Busy
    );
    assert_eq!(
        runtime.file_session(&dir.path().join("note.md")).unwrap(),
        Some(opened.status.session_id.clone())
    );
    runtime.abandon_document(&opened.status.session_id).unwrap();
    let target = runtime.save_target(&dir.path().join("note.md")).unwrap();
    assert_eq!(
        workspace
            .mutate(&runtime, Mutation::Move, "note.md", "new.md")
            .unwrap_err()
            .code,
        ErrorCode::Busy
    );
    runtime.release_save_target(target).unwrap();
    workspace
        .mutate(&runtime, Mutation::Move, "note.md", "new.md")
        .unwrap();
    assert_eq!(
        fs::read_to_string(dir.path().join("new.md")).unwrap(),
        "original"
    );
}
#[test]
fn reattach_and_close_are_scoped_to_one_document_and_duplicate_files_have_one_writer() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("one.md"), "one").unwrap();
    fs::write(dir.path().join("two.md"), "two").unwrap();
    let runtime = DocumentRuntime::default();
    let one = runtime.open_file(&dir.path().join("one.md"), None).unwrap();
    let two = runtime.open_file(&dir.path().join("two.md"), None).unwrap();
    assert_eq!(
        runtime
            .open_file(&dir.path().join("one.md"), None)
            .unwrap_err()
            .code,
        ErrorCode::Busy
    );
    #[cfg(unix)]
    {
        fs::hard_link(dir.path().join("one.md"), dir.path().join("alias.md")).unwrap();
        assert_eq!(
            runtime.file_session(&dir.path().join("alias.md")).unwrap(),
            Some(one.status.session_id.clone())
        );
        assert_eq!(
            runtime
                .open_file(&dir.path().join("alias.md"), None)
                .unwrap_err()
                .code,
            ErrorCode::Busy
        );
    }
    let renewed = runtime.reattach_document(&one.status.session_id).unwrap();
    assert_ne!(one.status.epoch, renewed.status.epoch);
    assert!(
        matches!(call(&runtime, Request::Status { session_id: two.status.session_id.clone() }), Response::Status { status } if status.epoch == two.status.epoch)
    );
    assert!(matches!(
        call(
            &runtime,
            Request::Close {
                session_id: renewed.status.session_id,
                epoch: renewed.status.epoch,
                revision: renewed.status.revision,
                discard: false
            }
        ),
        Response::Closed
    ));
    assert_eq!(
        runtime
            .document_path(&two.status.session_id)
            .unwrap()
            .unwrap(),
        dir.path()
            .join("two.md")
            .canonicalize()
            .unwrap()
            .to_str()
            .unwrap()
    );
}
#[test]
fn save_as_targets_have_independent_idempotent_leases_and_pending_saves_reserve_the_writer() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("target.md");
    fs::write(&path, "original").unwrap();
    let runtime = DocumentRuntime::default();
    let workspace = WorkspaceRuntime::open(dir.path()).unwrap();
    let first = runtime.save_target(&path).unwrap();
    let second = runtime.save_target(&path).unwrap();
    assert_ne!(first.reservation_id, second.reservation_id);
    runtime.release_save_target(first.clone()).unwrap();
    runtime.release_save_target(first).unwrap();
    assert_eq!(
        workspace
            .mutate(&runtime, Mutation::Move, "target.md", "renamed.md")
            .unwrap_err()
            .code,
        ErrorCode::Busy
    );
    let doc = runtime.new_document(None).unwrap();
    let prepared = call(
        &runtime,
        Request::PrepareSave {
            session_id: doc.status.session_id.clone(),
            epoch: doc.status.epoch.clone(),
            revision: doc.status.revision.clone(),
            target: Some(second.clone()),
        },
    );
    let Response::Prepared { ticket } = prepared else {
        panic!("expected a real save ticket")
    };
    assert_eq!(
        runtime.open_file(&path, None).unwrap_err().code,
        ErrorCode::Busy
    );
    assert_eq!(
        runtime.file_session(&path).unwrap(),
        Some(doc.status.session_id.clone())
    );
    assert!(matches!(
        call(
            &runtime,
            Request::AbortSave {
                session_id: doc.status.session_id,
                epoch: doc.status.epoch,
                ticket_id: ticket.ticket_id
            }
        ),
        Response::Aborted
    ));
    runtime.release_save_target(second).unwrap();
    workspace
        .mutate(&runtime, Mutation::Move, "target.md", "renamed.md")
        .unwrap();
    assert_eq!(
        fs::read_to_string(dir.path().join("renamed.md")).unwrap(),
        "original"
    );
    let legacy: lino_protocol::SaveTarget =
        serde_json::from_str(r#"{"file_ref":"1","expected_version":null,"label":"old.md"}"#)
            .unwrap();
    assert!(legacy.reservation_id.is_none());
}
#[test]
fn recursive_watcher_invalidates_once_until_the_next_read_and_releases_on_unwatch() {
    let dir = tempfile::tempdir().unwrap();
    fs::create_dir(dir.path().join("nested")).unwrap();
    let workspace = WorkspaceRuntime::open(dir.path()).unwrap();
    let (send, receive) = std::sync::mpsc::channel();
    workspace
        .watch(Arc::new(move || {
            let _ = send.send(());
        }))
        .unwrap();
    fs::write(dir.path().join("nested/a.md"), "first").unwrap();
    receive.recv_timeout(Duration::from_secs(5)).unwrap();
    workspace.list("nested", false).unwrap();
    fs::write(dir.path().join("nested/a.md"), "second").unwrap();
    receive.recv_timeout(Duration::from_secs(5)).unwrap();
    workspace.unwatch();
}
