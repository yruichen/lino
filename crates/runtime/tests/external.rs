use lino_protocol::{
    CloseIntent, Request, RequestEnvelope, Response, ResponseEnvelope, WireChange, PROTOCOL_VERSION,
};
use lino_runtime::DocumentRuntime;
use std::fs;
#[test]
fn external_changes_reload_and_read_only_preserve_the_original_on_failed_or_stale_operations() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("doc.md");
    fs::write(&path, "first").unwrap();
    let runtime = DocumentRuntime::default();
    let doc = runtime.open_file(&path, None).unwrap();
    let id = &doc.status.session_id;
    let file = doc.status.file_ref.as_deref().unwrap();
    assert_eq!(runtime.external_change(id, file).unwrap(), "unchanged");
    fs::write(&path, "other").unwrap();
    assert_eq!(runtime.external_change(id, file).unwrap(), "changed");
    let locked = runtime
        .set_document_read_only(id, &doc.status.epoch, "0", true)
        .unwrap();
    assert_eq!(locked.read_only, Some(true));
    let request = serde_json::to_string(&RequestEnvelope {
        protocol_version: PROTOCOL_VERSION,
        request_id: "edit".into(),
        operation: Request::ApplyChanges {
            session_id: id.clone(),
            epoch: doc.status.epoch.clone(),
            sequence: "1".into(),
            base_revision: "0".into(),
            changes: vec![WireChange {
                from: 0,
                to: 0,
                insert: "blocked".into(),
            }],
        },
    })
    .unwrap();
    assert!(matches!(
        serde_json::from_str::<ResponseEnvelope>(&runtime.dispatch(&request).unwrap())
            .unwrap()
            .result,
        Response::Error { .. }
    ));
    let intent = CloseIntent {
        session_id: id.clone(),
        epoch: doc.status.epoch,
        revision: "0".into(),
        discard: false,
    };
    fs::write(&path, b"\xff").unwrap();
    assert!(runtime.reload_document(intent.clone(), file).is_err());
    assert_eq!(runtime.reattach_document(id).unwrap().text, "first");
    // Reattachment invalidates the previous close/lock intent, never revives it.
    fs::write(&path, "valid").unwrap();
    assert!(runtime.reload_document(intent.clone(), file).is_err());
    let current = runtime.reattach_document(id).unwrap();
    let next = runtime
        .reload_document(
            CloseIntent {
                epoch: current.status.epoch,
                ..intent
            },
            file,
        )
        .unwrap();
    assert_eq!(next.text, "valid");
    assert_eq!(next.status.read_only, Some(true));
    fs::remove_file(path).unwrap();
    assert_eq!(
        runtime
            .external_change(&next.status.session_id, file)
            .unwrap(),
        "deleted"
    );
}
