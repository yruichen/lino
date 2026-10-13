use lino_protocol::{
    CloseIntent, ErrorCode, Request, RequestEnvelope, Response, ResponseEnvelope, WireChange,
    PROTOCOL_VERSION,
};
use lino_runtime::DocumentRuntime;
use std::{fs, sync::Arc};
fn call(runtime: &DocumentRuntime, operation: Request) -> Response {
    let request = serde_json::to_string(&RequestEnvelope {
        protocol_version: PROTOCOL_VERSION,
        request_id: "test".into(),
        operation,
    })
    .unwrap();
    serde_json::from_str::<ResponseEnvelope>(&runtime.dispatch(&request).unwrap())
        .unwrap()
        .result
}
#[test]
fn export_snapshot_and_resource_scope_survive_edits_and_save_as_but_do_not_overwrite_inputs() {
    let dir = tempfile::tempdir().unwrap();
    let original = dir.path().join("a.md");
    fs::write(&original, "old\r\n").unwrap();
    let svg = b"<svg xmlns=\"http://www.w3.org/2000/svg\"/>";
    fs::write(dir.path().join("image.svg"), svg).unwrap();
    let runtime = Arc::new(DocumentRuntime::default());
    let doc = runtime.open_file(&original, None).unwrap();
    let job = runtime
        .begin_export(
            &doc.status.session_id,
            &doc.status.epoch,
            &doc.status.revision,
        )
        .unwrap();
    assert!(matches!(
        call(
            &runtime,
            Request::ApplyChanges {
                session_id: doc.status.session_id.clone(),
                epoch: doc.status.epoch.clone(),
                sequence: "1".into(),
                base_revision: "0".into(),
                changes: vec![WireChange {
                    from: 0,
                    to: 0,
                    insert: "new".into()
                }]
            }
        ),
        Response::Applied { .. }
    ));
    assert_eq!(job.source().unwrap().text, "old\r\n");
    assert_eq!(job.read_image("image.svg").unwrap().bytes, svg);
    let other = dir.path().join("other");
    fs::create_dir(&other).unwrap();
    let save_as = runtime.save_target(&other.join("moved.md")).unwrap();
    let ticket = match call(
        &runtime,
        Request::PrepareSave {
            session_id: doc.status.session_id.clone(),
            epoch: doc.status.epoch.clone(),
            revision: "1".into(),
            target: Some(save_as.clone()),
        },
    ) {
        Response::Prepared { ticket } => ticket.ticket_id,
        other => panic!("{other:?}"),
    };
    assert!(matches!(
        call(
            &runtime,
            Request::CommitSave {
                session_id: doc.status.session_id.clone(),
                epoch: doc.status.epoch.clone(),
                ticket_id: ticket
            }
        ),
        Response::Saved { .. }
    ));
    runtime.release_save_target(save_as).unwrap();
    // The export grant remains rooted at its captured path, even after Save As.
    assert_eq!(job.read_image("image.svg").unwrap().bytes, svg);
    let source_target = runtime.save_target(&original).unwrap();
    assert_eq!(
        job.commit(source_target.clone(), b"bad").unwrap_err().code,
        ErrorCode::Denied
    );
    runtime.release_save_target(source_target).unwrap();
    let image_target = runtime.save_target(&dir.path().join("image.svg")).unwrap();
    assert_eq!(
        job.commit(image_target.clone(), b"bad").unwrap_err().code,
        ErrorCode::Denied
    );
    runtime.release_save_target(image_target).unwrap();
    let output = dir.path().join("output.pdf");
    let target = runtime.save_target(&output).unwrap();
    job.commit(target.clone(), b"%PDF-1.7\nsynthetic-byte-path\0\xff")
        .unwrap();
    runtime.release_save_target(target).unwrap();
    assert!(fs::read(&output).unwrap().ends_with(b"\0\xff"));
    assert!(!job.cancel());
    assert!(job.source().is_err());
    assert_eq!(fs::read_to_string(&original).unwrap(), "old\r\n");
    assert_eq!(fs::read(dir.path().join("image.svg")).unwrap(), svg);
}
#[test]
fn export_cancel_conflict_close_and_concurrency_bound_have_real_terminal_results() {
    let runtime = Arc::new(DocumentRuntime::default());
    let doc = runtime.new_document(None).unwrap();
    let jobs: Vec<_> = (0..4)
        .map(|_| {
            runtime
                .begin_export(&doc.status.session_id, &doc.status.epoch, "0")
                .unwrap()
        })
        .collect();
    assert!(runtime
        .begin_export(&doc.status.session_id, &doc.status.epoch, "0")
        .is_err());
    assert!(jobs[0].cancel());
    assert!(!jobs[0].cancel());
    let job = runtime
        .begin_export(&doc.status.session_id, &doc.status.epoch, "0")
        .unwrap();
    let dir = tempfile::tempdir().unwrap();
    let output = dir.path().join("output.html");
    let target = runtime.save_target(&output).unwrap();
    fs::write(&output, "external").unwrap();
    assert_eq!(
        job.commit(target.clone(), b"mine").unwrap_err().code,
        ErrorCode::ChangedExternally
    );
    assert!(!job.cancel());
    runtime.release_save_target(target).unwrap();
    assert_eq!(fs::read_to_string(&output).unwrap(), "external");
    jobs[1].begin_print().unwrap();
    assert!(!jobs[1].cancel());
    jobs[1].finish_print(false).unwrap();
    assert!(jobs[1].finish_print(true).is_err());
    runtime
        .new_document(Some(CloseIntent {
            session_id: doc.status.session_id,
            epoch: doc.status.epoch,
            revision: "0".into(),
            discard: false,
        }))
        .unwrap();
    assert!(jobs[2].source().is_err());
}
