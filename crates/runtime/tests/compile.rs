use lino_adapters::storage::FileStorage;
use lino_application::{
    compile::{
        ArtifactRef, CompileDiagnostic, CompileError, CompileOutcome, CompileOutput, CompileRequest,
    },
    ports::{CompilerPort, StoragePort},
};
use lino_protocol::{CompileJobState, CompileProfile};
use lino_runtime::DocumentRuntime;
use std::{
    fs,
    sync::{atomic::AtomicBool, Arc, Mutex},
};

struct FakeCompiler {
    outcomes: Mutex<Vec<Result<CompileOutcome, CompileError>>>,
}

impl FakeCompiler {
    fn new(outcomes: Vec<Result<CompileOutcome, CompileError>>) -> Self {
        Self {
            outcomes: Mutex::new(outcomes),
        }
    }
}

impl CompilerPort for FakeCompiler {
    fn compile(
        &self,
        _request: &CompileRequest,
        _cancelled: &AtomicBool,
    ) -> Result<CompileOutcome, CompileError> {
        self.outcomes.lock().unwrap().remove(0)
    }
}

fn success(artifact: u64, pdf: &[u8]) -> CompileOutcome {
    CompileOutcome::Succeeded(CompileOutput {
        artifact: ArtifactRef(artifact),
        pdf: pdf.to_vec(),
        log: "ok".into(),
        diagnostics: Vec::<CompileDiagnostic>::new(),
        compiler: "fake".into(),
    })
}

#[test]
fn compile_uses_fixed_snapshot_and_failed_job_keeps_last_successful_pdf() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("paper.tex");
    fs::write(&path, "\\begin{document}\nold\n\\end{document}\n").unwrap();
    let resources = Arc::new(FileStorage::default());
    let compiler = Arc::new(FakeCompiler::new(vec![
        Ok(success(1, b"%PDF-old")),
        Ok(CompileOutcome::Failed {
            log: "! LaTeX Error".into(),
            diagnostics: vec![CompileDiagnostic {
                file: Some("paper.tex".into()),
                line: Some(2),
                column: None,
                severity: lino_application::compile::CompileDiagnosticSeverity::Error,
                message: "bad source".into(),
            }],
        }),
    ]));
    let storage: Arc<dyn StoragePort> = resources.clone();
    let runtime = Arc::new(DocumentRuntime::with_compiler(resources, storage, compiler));
    let doc = runtime.open_file(&path, None).unwrap();
    let root = doc.status.file_ref.clone().unwrap();

    let first = runtime
        .begin_compile(
            &doc.status.session_id,
            &doc.status.epoch,
            "1",
            "1",
            &root,
            CompileProfile::LatexmkXelatex,
        )
        .unwrap();
    assert_eq!(first.request().source_revision.value(), 0);
    first.run().unwrap();
    let first_status = first.status().unwrap();
    assert_eq!(first_status.state, CompileJobState::Succeeded);
    assert_eq!(first_status.artifact_ref.as_deref(), Some("1"));
    assert_eq!(first.pdf().unwrap(), b"%PDF-old");

    let second = runtime
        .begin_compile(
            &doc.status.session_id,
            &doc.status.epoch,
            "1",
            "1",
            &root,
            CompileProfile::LatexmkXelatex,
        )
        .unwrap();
    second.run().unwrap();
    let second_status = second.status().unwrap();
    assert_eq!(second_status.state, CompileJobState::Failed);
    assert_eq!(second_status.artifact_ref.as_deref(), Some("1"));
    assert_eq!(second.pdf().unwrap(), b"%PDF-old");
    assert_eq!(second_status.diagnostics.len(), 1);

    let third = runtime
        .begin_compile(
            &doc.status.session_id,
            &doc.status.epoch,
            "1",
            "1",
            &root,
            CompileProfile::LatexmkXelatex,
        )
        .unwrap();
    assert!(third.cancel());
    assert_eq!(third.status().unwrap().state, CompileJobState::Cancelled);
}

#[test]
fn newer_project_generation_invalidates_an_older_compile_before_execution() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("paper.tex");
    fs::write(&path, "\\begin{document}x\\end{document}\n").unwrap();
    let resources = Arc::new(FileStorage::default());
    let compiler = Arc::new(FakeCompiler::new(vec![Ok(success(1, b"%PDF"))]));
    let storage: Arc<dyn StoragePort> = resources.clone();
    let runtime = Arc::new(DocumentRuntime::with_compiler(resources, storage, compiler));
    let doc = runtime.open_file(&path, None).unwrap();
    let root = doc.status.file_ref.clone().unwrap();
    let old = runtime
        .begin_compile(
            &doc.status.session_id,
            &doc.status.epoch,
            "9",
            "1",
            &root,
            CompileProfile::LatexmkXelatex,
        )
        .unwrap();
    let _new = runtime
        .begin_compile(
            &doc.status.session_id,
            &doc.status.epoch,
            "9",
            "2",
            &root,
            CompileProfile::LatexmkXelatex,
        )
        .unwrap();
    old.run().unwrap();
    let status = old.status().unwrap();
    assert_eq!(status.state, CompileJobState::Cancelled);
    assert!(status.stale);
}
