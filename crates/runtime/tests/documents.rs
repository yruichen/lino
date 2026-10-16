use lino_adapters::storage::FileStorage;
use lino_application::ports::{DiskVersion, LoadedFile, StorageCommit, StorageError, StoragePort};
use lino_document::FileRef;
use lino_protocol::{
    CloseIntent, ErrorCode, OpenedDocument, Request, RequestEnvelope, Response, ResponseEnvelope,
    WireChange, PROTOCOL_VERSION,
};
use lino_runtime::DocumentRuntime;
use std::{
    fs,
    sync::{Arc, Barrier},
    thread,
};

fn call(runtime: &DocumentRuntime, operation: Request) -> Response {
    let json = serde_json::to_string(&RequestEnvelope {
        protocol_version: PROTOCOL_VERSION,
        request_id: "test".into(),
        operation,
    })
    .unwrap();
    serde_json::from_str::<ResponseEnvelope>(&runtime.dispatch(&json).unwrap())
        .unwrap()
        .result
}
fn edit(runtime: &DocumentRuntime, doc: &OpenedDocument, sequence: u64, revision: u64, text: &str) {
    assert!(matches!(
        call(
            runtime,
            Request::ApplyChanges {
                session_id: doc.status.session_id.clone(),
                epoch: doc.status.epoch.clone(),
                sequence: sequence.to_string(),
                base_revision: revision.to_string(),
                changes: vec![WireChange {
                    from: 0,
                    to: 0,
                    insert: text.into()
                }]
            }
        ),
        Response::Applied { .. }
    ));
}
fn prepare(
    runtime: &DocumentRuntime,
    doc: &OpenedDocument,
    revision: u64,
    target: Option<lino_protocol::SaveTarget>,
) -> String {
    match call(
        runtime,
        Request::PrepareSave {
            session_id: doc.status.session_id.clone(),
            epoch: doc.status.epoch.clone(),
            revision: revision.to_string(),
            target,
        },
    ) {
        Response::Prepared { ticket } => ticket.ticket_id,
        other => panic!("{other:?}"),
    }
}
fn commit(runtime: &DocumentRuntime, doc: &OpenedDocument, ticket_id: String) -> Response {
    call(
        runtime,
        Request::CommitSave {
            session_id: doc.status.session_id.clone(),
            epoch: doc.status.epoch.clone(),
            ticket_id,
        },
    )
}
#[test]
fn open_edit_save_close_and_reopen_preserves_original_bytes_and_bom() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("中文.md");
    let initial = "# 中👩🏽‍💻\r\n\nB\r尾\n";
    fs::write(
        &path,
        [b"\xef\xbb\xbf".as_slice(), initial.as_bytes()].concat(),
    )
    .unwrap();
    let runtime = DocumentRuntime::default();
    let doc = runtime.open_file(&path, None).unwrap();
    assert!(doc.utf8_bom);
    assert_eq!(doc.text, initial);
    edit(&runtime, &doc, 1, 0, "新🙂\r\n");
    let ticket = prepare(&runtime, &doc, 1, None);
    assert!(matches!(
        commit(&runtime, &doc, ticket.clone()),
        Response::Saved { .. }
    ));
    assert!(matches!(
        commit(&runtime, &doc, ticket),
        Response::Saved { .. }
    ));
    assert!(matches!(
        call(
            &runtime,
            Request::Close {
                session_id: doc.status.session_id,
                epoch: doc.status.epoch,
                revision: "1".into(),
                discard: false
            }
        ),
        Response::Closed
    ));
    let reopened = runtime.open_file(&path, None).unwrap();
    assert_eq!(reopened.text, format!("新🙂\r\n{initial}"));
    assert!(!reopened.status.dirty);
    assert_eq!(
        fs::read(&path).unwrap(),
        [b"\xef\xbb\xbf".as_slice(), reopened.text.as_bytes()].concat()
    );
}
#[test]
fn failed_open_and_conflicting_save_keep_old_session_text_and_external_file() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("document.md");
    fs::write(&path, "disk").unwrap();
    let runtime = DocumentRuntime::default();
    let doc = runtime.open_file(&path, None).unwrap();
    edit(&runtime, &doc, 1, 0, "local ");
    let invalid = directory.path().join("invalid.md");
    fs::write(&invalid, [0xff]).unwrap();
    assert_eq!(
        runtime
            .open_file(
                &invalid,
                Some(CloseIntent {
                    session_id: doc.status.session_id.clone(),
                    epoch: doc.status.epoch.clone(),
                    revision: "1".into(),
                    discard: true
                })
            )
            .unwrap_err()
            .code,
        ErrorCode::UnsupportedEncoding
    );
    fs::write(&path, "else").unwrap();
    let ticket = prepare(&runtime, &doc, 1, None);
    assert!(
        matches!(commit(&runtime, &doc, ticket), Response::Error { error } if error.code == ErrorCode::ChangedExternally)
    );
    assert!(
        matches!(call(&runtime, Request::Status { session_id: doc.status.session_id.clone() }), Response::Status { status } if status.dirty && !status.saving && status.revision == "1")
    );
    assert_eq!(fs::read_to_string(&path).unwrap(), "else");
    // Export the retained local text to a new target after the failed save.
    let copy = directory.path().join("copy.md");
    let target = runtime.save_target(&copy).unwrap();
    let ticket = prepare(&runtime, &doc, 1, Some(target));
    assert!(matches!(
        commit(&runtime, &doc, ticket),
        Response::Saved { .. }
    ));
    assert_eq!(fs::read_to_string(copy).unwrap(), "local disk");
}
struct BlockingStorage {
    storage: Arc<FileStorage>,
    entered: Arc<Barrier>,
    release: Arc<Barrier>,
}

#[test]
fn external_conflict_overwrite_only_accepts_the_explicitly_observed_disk_version() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("conflict.md");
    fs::write(&path, "original").unwrap();
    let runtime = DocumentRuntime::default();
    let doc = runtime.open_file(&path, None).unwrap();
    edit(&runtime, &doc, 1, 0, "local ");
    fs::write(&path, "external").unwrap();
    let ticket = prepare(&runtime, &doc, 1, None);
    assert!(
        matches!(commit(&runtime, &doc, ticket), Response::Error { error } if error.code == ErrorCode::ChangedExternally)
    );

    // The native prompt captures this target before the user's decision.
    let observed = runtime.save_target(&path).unwrap();
    assert_eq!(observed.file_ref, doc.status.file_ref.clone().unwrap());
    fs::write(&path, "new external").unwrap();
    let ticket = prepare(&runtime, &doc, 1, Some(observed.clone()));
    assert!(
        matches!(commit(&runtime, &doc, ticket), Response::Error { error } if error.code == ErrorCode::ChangedExternally)
    );
    runtime.release_save_target(observed).unwrap();
    assert_eq!(fs::read_to_string(&path).unwrap(), "new external");
    assert!(
        matches!(call(&runtime, Request::Status { session_id: doc.status.session_id.clone() }), Response::Status { status } if status.dirty && !status.saving)
    );

    // A fresh explicit decision can save the retained local revision and close.
    let observed = runtime.save_target(&path).unwrap();
    let ticket = prepare(&runtime, &doc, 1, Some(observed.clone()));
    assert!(
        matches!(commit(&runtime, &doc, ticket), Response::Saved { status, .. } if !status.dirty && !status.saving)
    );
    runtime.release_save_target(observed).unwrap();
    assert_eq!(fs::read_to_string(&path).unwrap(), "local original");
    assert_eq!(
        runtime
            .external_change(
                &doc.status.session_id,
                doc.status.file_ref.as_deref().unwrap()
            )
            .unwrap(),
        "unchanged"
    );
    assert!(matches!(
        call(
            &runtime,
            Request::Close {
                session_id: doc.status.session_id,
                epoch: doc.status.epoch,
                revision: "1".into(),
                discard: false
            }
        ),
        Response::Closed
    ));
}
impl StoragePort for BlockingStorage {
    fn load(&self, f: FileRef) -> Result<LoadedFile, StorageError> {
        self.storage.load(f)
    }
    fn inspect(&self, f: FileRef) -> Result<Option<DiskVersion>, StorageError> {
        self.storage.inspect(f)
    }
    fn commit(&self, request: &StorageCommit) -> Result<(DiskVersion, bool), StorageError> {
        self.entered.wait();
        self.release.wait();
        self.storage.commit(request)
    }
}
#[test]
fn real_disk_save_does_not_hold_document_lock_or_save_later_edits() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("saved.md");
    let resources = Arc::new(FileStorage::default());
    let entered = Arc::new(Barrier::new(2));
    let release = Arc::new(Barrier::new(2));
    let runtime = Arc::new(DocumentRuntime::from_ports(
        resources.clone(),
        Arc::new(BlockingStorage {
            storage: resources,
            entered: entered.clone(),
            release: release.clone(),
        }),
    ));
    let doc = runtime.new_document(None).unwrap();
    edit(&runtime, &doc, 1, 0, "R");
    let target = runtime.save_target(&path).unwrap();
    let ticket = prepare(&runtime, &doc, 1, Some(target.clone()));
    // Replayed preparation resolves a lost reply to the identical fixed ticket.
    assert_eq!(prepare(&runtime, &doc, 1, Some(target)), ticket);
    let background = {
        let runtime = runtime.clone();
        let doc = doc.clone();
        thread::spawn(move || commit(&runtime, &doc, ticket))
    };
    entered.wait();
    edit(&runtime, &doc, 2, 1, "R+1 ");
    release.wait();
    assert!(
        matches!(background.join().unwrap(), Response::Saved { receipt, status } if receipt.revision == "1" && status.revision == "2" && status.dirty)
    );
    assert_eq!(fs::read_to_string(path).unwrap(), "R");
}
#[test]
fn protocol_rejects_version_extra_fields_and_unknown_operations() {
    let runtime = DocumentRuntime::default();
    for (json, expected) in [
        (
            r#"{"protocol_version":99,"request_id":"x","operation":{"kind":"handshake","resource_version":"0.0.1"}}"#,
            ErrorCode::ProtocolMismatch,
        ),
        (
            r#"{"protocol_version":1,"request_id":"x","operation":{"kind":"status","session_id":"1","path":"/anything"}}"#,
            ErrorCode::InvalidMessage,
        ),
        (
            r#"{"protocol_version":1,"request_id":"x","operation":{"kind":"future"}}"#,
            ErrorCode::UnsupportedOperation,
        ),
    ] {
        let response: ResponseEnvelope =
            serde_json::from_str(&runtime.dispatch(json).unwrap()).unwrap();
        assert_eq!(response.request_id, "x");
        assert!(matches!(response.result, Response::Error { error } if error.code == expected));
    }
}
