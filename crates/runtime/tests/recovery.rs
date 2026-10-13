#[cfg(unix)]
use lino_adapters::recovery::FileRecovery;
#[cfg(unix)]
use lino_application::{
    ports::StorageError,
    recovery::{RecoveredText, RecoveryEntry, RecoveryPort, RecoverySnapshot},
};
use lino_protocol::{
    ErrorCode, OpenedDocument, Request, RequestEnvelope, Response, ResponseEnvelope, WireChange,
    PROTOCOL_VERSION,
};
use lino_runtime::DocumentRuntime;
use std::path::Path;
#[cfg(unix)]
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc,
    },
    thread,
    time::Duration,
};
fn call(runtime: &DocumentRuntime, operation: Request) -> Response {
    serde_json::from_str::<ResponseEnvelope>(
        &runtime
            .dispatch(
                &serde_json::to_string(&RequestEnvelope {
                    protocol_version: PROTOCOL_VERSION,
                    request_id: "recovery-test".into(),
                    operation,
                })
                .unwrap(),
            )
            .unwrap(),
    )
    .unwrap()
    .result
}
fn edit(
    runtime: &DocumentRuntime,
    doc: &OpenedDocument,
    sequence: u64,
    base: u64,
    text: &str,
) -> Response {
    call(
        runtime,
        Request::ApplyChanges {
            session_id: doc.status.session_id.clone(),
            epoch: doc.status.epoch.clone(),
            sequence: sequence.to_string(),
            base_revision: base.to_string(),
            changes: vec![WireChange {
                from: 0,
                to: 0,
                insert: text.into(),
            }],
        },
    )
}
fn checkpoint(runtime: &DocumentRuntime, doc: &OpenedDocument) -> Response {
    call(
        runtime,
        Request::Checkpoint {
            session_id: doc.status.session_id.clone(),
            epoch: doc.status.epoch.clone(),
        },
    )
}
#[cfg(unix)]
fn close(runtime: &DocumentRuntime, doc: &OpenedDocument, revision: u64) -> Response {
    call(
        runtime,
        Request::Close {
            session_id: doc.status.session_id.clone(),
            epoch: doc.status.epoch.clone(),
            revision: revision.to_string(),
            discard: true,
        },
    )
}
#[test]
fn recovery_worker() {
    let Some(directory) = std::env::var_os("OPEN_TYPORA_RECOVERY_FIXTURE") else {
        return;
    };
    let runtime = DocumentRuntime::default();
    runtime.configure_recovery(Path::new(&directory)).unwrap();
    let doc = runtime.new_document(None).unwrap();
    assert!(matches!(
        edit(&runtime, &doc, 1, 0, "持久化👩\r\nA\rB"),
        Response::Applied { .. }
    ));
    assert!(matches!(
        checkpoint(&runtime, &doc),
        Response::Checkpointed { .. }
    ));
    assert!(matches!(
        edit(&runtime, &doc, 2, 1, "尚未持久化"),
        Response::Applied { .. }
    ));
    // Exit without running destructors or a shutdown checkpoint.
    std::process::exit(0);
}
#[test]
fn abrupt_exit_restores_only_checkpoint_and_never_binds_original_file() {
    let dir = tempfile::tempdir().unwrap();
    assert!(std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "recovery_worker", "--nocapture"])
        .env("OPEN_TYPORA_RECOVERY_FIXTURE", dir.path())
        .status()
        .unwrap()
        .success());
    let runtime = DocumentRuntime::default();
    runtime.configure_recovery(dir.path()).unwrap();
    let entries = runtime.list_recoveries().unwrap();
    assert_eq!(entries.len(), 1);
    let doc = runtime.restore_recovery(&entries[0].key, None).unwrap();
    assert_eq!(doc.text, "持久化👩\r\nA\rB");
    assert!(doc.status.dirty);
    assert!(doc.status.file_ref.is_none());
    assert!(runtime.list_recoveries().unwrap().is_empty());
    assert_eq!(
        runtime.discard_recovery(&entries[0].key).unwrap_err().code,
        ErrorCode::Busy
    );
    assert!(matches!(
        edit(&runtime, &doc, 1, 0, "恢复后"),
        Response::Applied { .. }
    ));
    #[cfg(unix)]
    {
        assert!(matches!(close(&runtime, &doc, 1), Response::Closed));
    }
}
#[test]
fn webview_renewal_keeps_accepted_text_and_rejects_old_callbacks() {
    let runtime = DocumentRuntime::default();
    let doc = runtime.new_document(None).unwrap();
    assert!(matches!(
        edit(&runtime, &doc, 1, 0, "已接收"),
        Response::Applied { .. }
    ));
    let next = runtime.reattach_document(&doc.status.session_id).unwrap();
    assert_eq!(next.text, "已接收");
    assert_ne!(next.status.epoch, doc.status.epoch);
    assert!(
        matches!(edit(&runtime, &doc, 2, 1, "迟到"), Response::Error { error } if error.code == ErrorCode::OldEpoch)
    );
    assert!(
        matches!(checkpoint(&runtime, &doc), Response::Error { error } if error.code == ErrorCode::OldEpoch)
    );
    assert!(matches!(
        edit(&runtime, &next, 1, 1, "新租约"),
        Response::Applied { .. }
    ));
}
#[cfg(unix)]
struct ControlledRecovery {
    inner: FileRecovery,
    entered: Option<mpsc::SyncSender<()>>,
    release: mpsc::Receiver<()>,
    fail_retire: Arc<AtomicBool>,
}
#[cfg(unix)]
impl RecoveryPort for ControlledRecovery {
    fn list(&self) -> Result<Vec<RecoveryEntry>, StorageError> {
        self.inner.list()
    }
    fn read(&self, key: &str) -> Result<RecoveredText, StorageError> {
        self.inner.read(key)
    }
    fn write(
        &mut self,
        key: Option<&str>,
        value: &RecoverySnapshot,
    ) -> Result<(String, bool), StorageError> {
        if let Some(entered) = self.entered.take() {
            entered.send(()).unwrap();
            self.release.recv_timeout(Duration::from_secs(10)).unwrap();
        }
        self.inner.write(key, value)
    }
    fn retire(&mut self, key: &str) -> Result<(), StorageError> {
        if self.fail_retire.load(Ordering::SeqCst) {
            Err(StorageError::Denied)
        } else {
            self.inner.retire(key)
        }
    }
}
#[cfg(unix)]
#[test]
fn checkpoint_io_does_not_block_input_and_discard_cannot_resurrect() {
    let dir = tempfile::tempdir().unwrap();
    let runtime = Arc::new(DocumentRuntime::default());
    let (entered_tx, entered_rx) = mpsc::sync_channel(1);
    let (release_tx, release_rx) = mpsc::sync_channel(1);
    runtime
        .set_recovery_port(Box::new(ControlledRecovery {
            inner: FileRecovery::open(dir.path()).unwrap(),
            entered: Some(entered_tx),
            release: release_rx,
            fail_retire: Arc::new(AtomicBool::new(false)),
        }))
        .unwrap();
    let doc = runtime.new_document(None).unwrap();
    edit(&runtime, &doc, 1, 0, "R");
    let writer = {
        let runtime = runtime.clone();
        let doc = doc.clone();
        thread::spawn(move || checkpoint(&runtime, &doc))
    };
    entered_rx.recv_timeout(Duration::from_secs(10)).unwrap();
    assert!(matches!(
        edit(&runtime, &doc, 2, 1, "R+1"),
        Response::Applied { .. }
    ));
    release_tx.send(()).unwrap();
    assert!(
        matches!(writer.join().unwrap(), Response::Checkpointed { revision, durable: true } if revision == "1")
    );
    assert!(matches!(close(&runtime, &doc, 2), Response::Closed));
    assert!(
        matches!(checkpoint(&runtime, &doc), Response::Error { error } if error.code == ErrorCode::UnknownSession)
    );
    assert!(runtime.list_recoveries().unwrap().is_empty());
}
#[cfg(unix)]
#[test]
fn retirement_failure_keeps_session_editable_and_preserves_previous_copy() {
    let dir = tempfile::tempdir().unwrap();
    let runtime = DocumentRuntime::default();
    let (_release_tx, release_rx) = mpsc::sync_channel(1);
    let fail = Arc::new(AtomicBool::new(true));
    runtime
        .set_recovery_port(Box::new(ControlledRecovery {
            inner: FileRecovery::open(dir.path()).unwrap(),
            entered: None,
            release: release_rx,
            fail_retire: fail.clone(),
        }))
        .unwrap();
    let doc = runtime.new_document(None).unwrap();
    edit(&runtime, &doc, 1, 0, "protected");
    checkpoint(&runtime, &doc);
    assert!(
        matches!(close(&runtime, &doc, 1), Response::Error { error } if error.code == ErrorCode::Denied)
    );
    assert!(matches!(
        edit(&runtime, &doc, 2, 1, "still editable "),
        Response::Applied { .. }
    ));
    fail.store(false, Ordering::SeqCst);
    assert!(matches!(close(&runtime, &doc, 2), Response::Closed));
}
#[test]
fn malformed_recovery_does_not_replace_active_document() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("draft-broken.recovery"), "bad").unwrap();
    let runtime = DocumentRuntime::default();
    runtime.configure_recovery(dir.path()).unwrap();
    let doc = runtime.new_document(None).unwrap();
    edit(&runtime, &doc, 1, 0, "current");
    assert!(runtime
        .restore_recovery(
            "draft-broken.recovery",
            Some(lino_protocol::CloseIntent {
                session_id: doc.status.session_id.clone(),
                epoch: doc.status.epoch,
                revision: "1".into(),
                discard: true
            })
        )
        .is_err());
    assert_eq!(
        runtime
            .reattach_document(&doc.status.session_id)
            .unwrap()
            .text,
        "current"
    );
    assert_eq!(
        std::fs::read(dir.path().join("draft-broken.recovery")).unwrap(),
        b"bad"
    );
}

#[cfg(unix)]
#[test]
fn failed_directory_sync_after_delete_invalidates_cached_durability() {
    struct DeleteThenFail(FileRecovery);
    impl RecoveryPort for DeleteThenFail {
        fn list(&self) -> Result<Vec<RecoveryEntry>, StorageError> {
            self.0.list()
        }
        fn read(&self, key: &str) -> Result<RecoveredText, StorageError> {
            self.0.read(key)
        }
        fn write(
            &mut self,
            key: Option<&str>,
            value: &RecoverySnapshot,
        ) -> Result<(String, bool), StorageError> {
            self.0.write(key, value)
        }
        fn retire(&mut self, key: &str) -> Result<(), StorageError> {
            self.0.retire(key)?;
            Err(StorageError::Io(
                "injected directory sync failure after unlink".into(),
            ))
        }
    }
    let dir = tempfile::tempdir().unwrap();
    let runtime = DocumentRuntime::default();
    runtime
        .set_recovery_port(Box::new(DeleteThenFail(
            FileRecovery::open(dir.path()).unwrap(),
        )))
        .unwrap();
    let doc = runtime.new_document(None).unwrap();
    edit(&runtime, &doc, 1, 0, "must remain protected");
    checkpoint(&runtime, &doc);
    assert!(matches!(close(&runtime, &doc, 1), Response::Error { .. }));
    assert!(matches!(
        checkpoint(&runtime, &doc),
        Response::Checkpointed { durable: true, .. }
    ));
    drop(runtime);
    let store = FileRecovery::open(dir.path()).unwrap();
    let entries = store.list().unwrap();
    assert_eq!(entries.len(), 1);
    assert_eq!(
        store.read(&entries[0].key).unwrap().text,
        "must remain protected"
    );
}

#[cfg(unix)]
#[test]
fn unconfirmed_original_directory_sync_keeps_recovery_after_clean_close() {
    use lino_adapters::storage::FileStorage;
    use lino_application::ports::{DiskVersion, LoadedFile, StorageCommit, StoragePort};
    use lino_document::FileRef;
    struct UnconfirmedSave(Arc<FileStorage>);
    impl StoragePort for UnconfirmedSave {
        fn load(&self, file: FileRef) -> Result<LoadedFile, StorageError> {
            self.0.load(file)
        }
        fn inspect(&self, file: FileRef) -> Result<Option<DiskVersion>, StorageError> {
            self.0.inspect(file)
        }
        fn commit(&self, request: &StorageCommit) -> Result<(DiskVersion, bool), StorageError> {
            self.0.commit(request).map(|(version, _)| (version, false))
        }
    }
    let dir = tempfile::tempdir().unwrap();
    let recovery = dir.path().join("recovery");
    let path = dir.path().join("source.md");
    std::fs::write(&path, "original").unwrap();
    let files = Arc::new(FileStorage::default());
    let runtime = DocumentRuntime::from_ports(files.clone(), Arc::new(UnconfirmedSave(files)));
    runtime.configure_recovery(&recovery).unwrap();
    let doc = runtime.open_file(&path, None).unwrap();
    edit(&runtime, &doc, 1, 0, "new ");
    let ticket = match call(
        &runtime,
        Request::PrepareSave {
            session_id: doc.status.session_id.clone(),
            epoch: doc.status.epoch.clone(),
            revision: "1".into(),
            target: None,
        },
    ) {
        Response::Prepared { ticket } => ticket,
        other => panic!("{other:?}"),
    };
    assert!(
        matches!(call(&runtime, Request::CommitSave { session_id: doc.status.session_id.clone(), epoch: doc.status.epoch.clone(), ticket_id: ticket.ticket_id }), Response::Saved { receipt, status } if !receipt.durable && !status.dirty)
    );
    assert!(matches!(
        checkpoint(&runtime, &doc),
        Response::Checkpointed { durable: true, .. }
    ));
    assert!(matches!(
        call(
            &runtime,
            Request::Close {
                session_id: doc.status.session_id.clone(),
                epoch: doc.status.epoch,
                revision: "1".into(),
                discard: false
            }
        ),
        Response::Closed
    ));
    let copies = runtime.list_recoveries().unwrap();
    assert_eq!(copies.len(), 1);
    let restored = runtime.restore_recovery(&copies[0].key, None).unwrap();
    assert_eq!(restored.text, "new original");
    assert_eq!(std::fs::read_to_string(path).unwrap(), "new original");
}

#[test]
fn save_as_updates_recovery_label_even_when_revision_is_unchanged() {
    let dir = tempfile::tempdir().unwrap();
    let recovery = dir.path().join("recovery");
    let runtime = DocumentRuntime::default();
    runtime.configure_recovery(&recovery).unwrap();
    let doc = runtime.new_document(None).unwrap();
    edit(&runtime, &doc, 1, 0, "R");
    let target = runtime
        .save_target(&dir.path().join("new-name.md"))
        .unwrap();
    let ticket = match call(
        &runtime,
        Request::PrepareSave {
            session_id: doc.status.session_id.clone(),
            epoch: doc.status.epoch.clone(),
            revision: "1".into(),
            target: Some(target),
        },
    ) {
        Response::Prepared { ticket } => ticket,
        other => panic!("{other:?}"),
    };
    edit(&runtime, &doc, 2, 1, "R+1 ");
    checkpoint(&runtime, &doc);
    assert!(
        matches!(call(&runtime, Request::CommitSave { session_id: doc.status.session_id.clone(), epoch: doc.status.epoch.clone(), ticket_id: ticket.ticket_id }), Response::Saved { status, .. } if status.dirty)
    );
    checkpoint(&runtime, &doc);
    drop(runtime);
    let runtime = DocumentRuntime::default();
    runtime.configure_recovery(&recovery).unwrap();
    let entries = runtime.list_recoveries().unwrap();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].label.as_deref(), Some("new-name.md"));
    assert_eq!(
        runtime
            .restore_recovery(&entries[0].key, None)
            .unwrap()
            .text,
        "R+1 R"
    );
}
