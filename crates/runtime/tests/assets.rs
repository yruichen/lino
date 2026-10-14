use lino_protocol::ErrorCode;
use lino_runtime::DocumentRuntime;
use std::fs;
const PNG: &[u8] = b"\x89PNG\r\n\x1a\nsynthetic-payload";
#[test]
fn save_as_copies_bound_resources_without_clobbering_conflicts_or_changing_relative_paths() {
    use lino_protocol::{
        Request, RequestEnvelope, Response, ResponseEnvelope, SaveImagesRequest, PROTOCOL_VERSION,
    };
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("source");
    let target = dir.path().join("target");
    fs::create_dir(&source).unwrap();
    fs::create_dir(&target).unwrap();
    let original = source.join("original.md");
    fs::write(&original, "![x](nested/image.png)").unwrap();
    fs::create_dir(source.join("nested")).unwrap();
    fs::write(source.join("nested/image.png"), PNG).unwrap();
    let runtime = DocumentRuntime::default();
    let doc = runtime.open_file(&original, None).unwrap();
    let save = runtime.save_target(&target.join("new.md")).unwrap();
    let json = serde_json::to_string(&RequestEnvelope {
        protocol_version: PROTOCOL_VERSION,
        request_id: "prepare".into(),
        operation: Request::PrepareSave {
            session_id: doc.status.session_id.clone(),
            epoch: doc.status.epoch.clone(),
            revision: "0".into(),
            target: Some(save.clone()),
        },
    })
    .unwrap();
    let reply =
        serde_json::from_str::<ResponseEnvelope>(&runtime.dispatch(&json).unwrap()).unwrap();
    let ticket_id = match reply.result {
        Response::Prepared { ticket } => ticket.ticket_id,
        other => panic!("{other:?}"),
    };
    let request = || SaveImagesRequest {
        ticket_id: ticket_id.clone(),
        target: save.clone(),
        sources: vec!["nested/image.png".into()],
    };
    runtime
        .copy_save_images(
            &doc.status.session_id,
            doc.status.file_ref.as_deref(),
            request(),
        )
        .unwrap();
    assert_eq!(fs::read(target.join("nested/image.png")).unwrap(), PNG);
    runtime
        .copy_save_images(
            &doc.status.session_id,
            doc.status.file_ref.as_deref(),
            request(),
        )
        .unwrap();
    fs::write(target.join("nested/image.png"), b"\x89PNG\r\n\x1a\nother").unwrap();
    assert_eq!(
        runtime
            .copy_save_images(
                &doc.status.session_id,
                doc.status.file_ref.as_deref(),
                request()
            )
            .unwrap_err()
            .code,
        ErrorCode::ChangedExternally
    );
    assert_eq!(
        fs::read(target.join("nested/image.png")).unwrap(),
        b"\x89PNG\r\n\x1a\nother"
    );
    assert!(!target.join("new.md").exists());
    assert_eq!(
        fs::read_to_string(&original).unwrap(),
        "![x](nested/image.png)"
    );
    runtime.release_save_target(save).unwrap();
}
#[test]
fn local_document_links_are_scoped_to_the_bound_file_and_never_resolve_arbitrary_files() {
    let dir = tempfile::tempdir().unwrap();
    let original = dir.path().join("original.md");
    fs::write(&original, "source").unwrap();
    fs::write(dir.path().join("中文 note.md"), "# Target").unwrap();
    fs::write(dir.path().join("script.sh"), "exit 0").unwrap();
    let runtime = DocumentRuntime::default();
    let doc = runtime.open_file(&original, None).unwrap();
    let id = &doc.status.session_id;
    let file = doc.status.file_ref.as_deref();
    assert_eq!(
        runtime
            .document_link_path(id, file, "中文%20note.md")
            .unwrap(),
        fs::canonicalize(dir.path().join("中文 note.md"))
            .unwrap()
            .to_string_lossy()
    );
    assert_eq!(
        runtime
            .document_link_path(id, None, "中文%20note.md")
            .unwrap_err()
            .code,
        ErrorCode::StaleRevision
    );
    for source in [
        "../outside.md",
        "%2e%2e/outside.md",
        "/etc/passwd",
        "https://example.invalid",
        "script.sh",
    ] {
        assert!(
            runtime.document_link_path(id, file, source).is_err(),
            "{source}"
        );
    }
}
fn request(
    runtime: &DocumentRuntime,
    operation: lino_protocol::Request,
) -> lino_protocol::Response {
    let json = serde_json::to_string(&lino_protocol::RequestEnvelope {
        protocol_version: lino_protocol::PROTOCOL_VERSION,
        request_id: "assets-fixture".into(),
        operation,
    })
    .unwrap();
    serde_json::from_str::<lino_protocol::ResponseEnvelope>(&runtime.dispatch(&json).unwrap())
        .unwrap()
        .result
}
#[test]
fn imported_resources_are_real_no_clobber_copies_and_require_a_bound_live_document() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("中文.md");
    fs::write(&path, "text").unwrap();
    let runtime = DocumentRuntime::default();
    let unsaved = runtime.new_document(None).unwrap();
    assert_eq!(
        runtime
            .read_image(&unsaved.status.session_id, None, "图片 assets/日出.svg")
            .unwrap_err()
            .code,
        ErrorCode::NotSaved
    );
    assert_eq!(
        runtime
            .import_image(&unsaved.status.session_id, None, "a.png", PNG)
            .unwrap_err()
            .code,
        ErrorCode::NotSaved
    );
    let doc = runtime.open_file(&path, None).unwrap();
    let id = &doc.status.session_id;
    let file = doc.status.file_ref.as_deref();
    let first = runtime.import_image(id, file, "picture.png", PNG).unwrap();
    let second = runtime.import_image(id, file, "picture.png", PNG).unwrap();
    assert_ne!(first, second);
    assert_eq!(runtime.read_image(id, file, &first).unwrap().bytes, PNG);
    assert_eq!(fs::read(dir.path().join(&second)).unwrap(), PNG);
    assert_eq!(fs::read_to_string(path).unwrap(), "text");
    assert_eq!(
        runtime.read_image("999", file, &first).unwrap_err().code,
        ErrorCode::UnknownSession
    );
    assert_eq!(
        runtime
            .import_image(id, file, "fake.png", b"not an image")
            .unwrap_err()
            .code,
        ErrorCode::UnsupportedFile
    );
}
#[test]
fn local_image_reads_resolve_document_relative_parents_and_reject_symlinks_and_non_images() {
    let dir = tempfile::tempdir().unwrap();
    fs::write(dir.path().join("note.md"), "text").unwrap();
    fs::write(dir.path().join("a b.png"), PNG).unwrap();
    let runtime = DocumentRuntime::default();
    let doc = runtime
        .open_file(&dir.path().join("note.md"), None)
        .unwrap();
    let id = &doc.status.session_id;
    let file = doc.status.file_ref.as_deref();
    assert_eq!(
        runtime.read_image(id, file, "a%20b.png").unwrap().mime,
        "image/png"
    );
    let svg = br#"<svg xmlns="http://www.w3.org/2000/svg" width="2" height="2"><rect width="2" height="2"/></svg>"#;
    fs::create_dir(dir.path().join("图片 assets")).unwrap();
    fs::write(dir.path().join("图片 assets/日出.svg"), svg).unwrap();
    let image = runtime
        .read_image(id, file, "图片%20assets/日出.svg")
        .unwrap();
    assert_eq!(image.mime, "image/svg+xml");
    assert_eq!(image.bytes, svg);
    let nested = dir.path().join("draft/v11");
    fs::create_dir_all(&nested).unwrap();
    fs::write(nested.join("paper.md"), "![figure](../figures/a%20b.png)").unwrap();
    fs::create_dir(dir.path().join("draft/figures")).unwrap();
    fs::write(dir.path().join("draft/figures/a b.png"), PNG).unwrap();
    let paper = runtime.open_file(&nested.join("paper.md"), None).unwrap();
    for source in [
        "../figures/a%20b.png",
        "%2e%2e/figures/a%20b.png",
        "../../a%20b.png",
        "./../figures/a%20b.png",
    ] {
        assert_eq!(
            runtime
                .read_image(
                    &paper.status.session_id,
                    paper.status.file_ref.as_deref(),
                    source
                )
                .unwrap()
                .bytes,
            PNG
        );
    }
    assert!(runtime
        .read_image(&paper.status.session_id, None, "../../a%20b.png")
        .is_err());
    assert_eq!(
        runtime
            .image_path(
                &paper.status.session_id,
                paper.status.file_ref.as_deref(),
                "../figures/a%20b.png"
            )
            .unwrap(),
        dir.path()
            .join("draft/figures/a b.png")
            .canonicalize()
            .unwrap()
            .to_string_lossy()
    );
    for source in [
        "../outside.png",
        "%2e%2e/outside.png",
        "/etc/passwd",
        "bad%",
        "https://example.invalid/a.png",
        "note.md",
    ] {
        assert!(runtime.read_image(id, file, source).is_err(), "{source}");
    }
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(
            dir.path().join("draft/figures"),
            dir.path().join("draft/alias"),
        )
        .unwrap();
        assert!(runtime
            .read_image(
                &paper.status.session_id,
                paper.status.file_ref.as_deref(),
                "../alias/a%20b.png"
            )
            .is_err());
        std::os::unix::fs::symlink(dir.path().join("a b.png"), dir.path().join("alias.png"))
            .unwrap();
        assert!(runtime.read_image(id, file, "alias.png").is_err());
        std::os::unix::fs::symlink(dir.path(), dir.path().join("note.md.assets")).unwrap();
        assert!(runtime.import_image(id, file, "x.png", PNG).is_err());
    }
}
#[test]
fn save_as_changes_resource_scope_and_old_requests_cannot_read_or_write_the_new_directory() {
    use lino_protocol::{Request, Response};
    let old = tempfile::tempdir().unwrap();
    let new = tempfile::tempdir().unwrap();
    fs::write(old.path().join("note.md"), "![x](x.png)").unwrap();
    fs::write(old.path().join("x.png"), PNG).unwrap();
    let different = [PNG, b"different-image"].concat();
    fs::write(new.path().join("x.png"), &different).unwrap();
    let runtime = DocumentRuntime::default();
    let doc = runtime
        .open_file(&old.path().join("note.md"), None)
        .unwrap();
    let id = &doc.status.session_id;
    let file = doc.status.file_ref.as_deref();
    assert_eq!(runtime.read_image(id, file, "x.png").unwrap().bytes, PNG);
    let target = runtime.save_target(&new.path().join("note.md")).unwrap();
    let new_file = target.file_ref.clone();
    let Response::Prepared { ticket } = request(
        &runtime,
        Request::PrepareSave {
            session_id: id.clone(),
            epoch: doc.status.epoch.clone(),
            revision: doc.status.revision.clone(),
            target: Some(target.clone()),
        },
    ) else {
        panic!("save preparation failed");
    };
    let result = request(
        &runtime,
        Request::CommitSave {
            session_id: id.clone(),
            epoch: doc.status.epoch.clone(),
            ticket_id: ticket.ticket_id,
        },
    );
    assert!(!matches!(result, Response::Error { .. }), "{result:?}");
    runtime.release_save_target(target).unwrap();
    assert_eq!(
        runtime.read_image(id, file, "x.png").unwrap_err().code,
        ErrorCode::StaleRevision
    );
    assert_eq!(
        runtime
            .import_image(id, file, "late.png", PNG)
            .unwrap_err()
            .code,
        ErrorCode::StaleRevision
    );
    assert!(!new.path().join("note.md.assets").exists());
    assert!(!old.path().join("note.md.assets").exists());
    assert_eq!(
        runtime
            .read_image(id, Some(&new_file), "x.png")
            .unwrap()
            .bytes,
        different
    );
    assert_eq!(
        fs::read_to_string(new.path().join("note.md")).unwrap(),
        "![x](x.png)"
    );
}

#[test]
fn selected_images_default_to_absolute_references_without_creating_assets_or_requiring_a_saved_document(
) {
    let dir = tempfile::tempdir().unwrap();
    let image = dir.path().join("original.png");
    fs::write(&image, PNG).unwrap();
    let image = image.canonicalize().unwrap();
    let runtime = DocumentRuntime::default();
    let doc = runtime.new_document(None).unwrap();
    let source = runtime
        .import_image_file(&doc.status.session_id, None, &image)
        .unwrap();
    assert_eq!(source, image.to_string_lossy());
    assert_eq!(
        runtime
            .read_image(&doc.status.session_id, None, &source)
            .unwrap()
            .bytes,
        PNG
    );
    assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 1);
    assert!(runtime.read_image("999", None, &source).is_err());
    let note = dir.path().join("note.md");
    fs::write(&note, "").unwrap();
    let bound = runtime.open_file(&note, None).unwrap();
    assert_eq!(
        runtime
            .import_image_file(
                &bound.status.session_id,
                bound.status.file_ref.as_deref(),
                &image
            )
            .unwrap(),
        source
    );
    assert!(!dir.path().join("note.md.assets").exists());
    let current = runtime
        .configure_preferences(&dir.path().join("settings.json"), None, None)
        .unwrap();
    let mut values = current.values;
    values.image_insertion = "copy".into();
    runtime
        .update_preferences(&current.revision, values)
        .unwrap();
    let copied = runtime
        .import_image_file(
            &bound.status.session_id,
            bound.status.file_ref.as_deref(),
            &image,
        )
        .unwrap();
    assert_eq!(copied, "note.md.assets/original.png");
    assert!(dir.path().join(&copied).is_file());
}
