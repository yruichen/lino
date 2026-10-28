use crate::{
    dispatch::{error, number},
    DocumentRuntime,
};
use lino_application::{
    compile::{CompileDiagnostic, CompileError, CompileOutcome, CompileProfile, CompileRequest},
    document_types::DocumentKind,
    jobs::{CompileJobLifecycle, CompileJobState, JobId},
    projects::{ProjectGeneration, ProjectId, RootFileRef},
};
use lino_document::{EditorEpoch, FileRef, SessionId};
use lino_protocol::{
    CompileDiagnosticSeverity, CompileJobState as WireState, CompileProfile as WireProfile,
    CompileStatus, ErrorCode, WireError,
};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, Weak,
    },
};

#[derive(Default)]
pub(crate) struct Compiles {
    next: u64,
    next_project: u64,
    projects: HashMap<RootFileRef, ProjectId>,
    jobs: Vec<Weak<CompileJob>>,
    generations: HashMap<ProjectId, ProjectGeneration>,
    latest: HashMap<ProjectId, lino_application::compile::CompileOutput>,
}

pub struct CompileJob {
    id: JobId,
    runtime: Arc<DocumentRuntime>,
    request: CompileRequest,
    state: Mutex<CompileJobLifecycle>,
    cancelled: Arc<AtomicBool>,
    outcome: Mutex<Option<CompileOutcome>>,
    error: Mutex<Option<CompileError>>,
}

impl DocumentRuntime {
    pub fn begin_document_compile(
        self: &Arc<Self>,
        session: &str,
        epoch: &str,
        profile: WireProfile,
    ) -> Result<Arc<CompileJob>, WireError> {
        let session_id = SessionId(number(session)?);
        let expected_epoch = EditorEpoch(number(epoch)?);
        let info = self.info(session_id)?;
        if info.epoch != expected_epoch {
            return Err(error(ErrorCode::OldEpoch, "编辑视图已变化。", false));
        }
        let root_file =
            RootFileRef(info.file.ok_or_else(|| {
                error(ErrorCode::NotSaved, "LaTeX 文档必须先保存才能编译。", false)
            })?);
        let (project_id, generation) = {
            let mut compiles = self
                .compiles
                .lock()
                .map_err(|_| error(ErrorCode::Internal, "Compile registry poisoned", false))?;
            let next_project = if let Some(id) = compiles.projects.get(&root_file) {
                *id
            } else {
                compiles.next_project = compiles.next_project.checked_add(1).ok_or_else(|| {
                    error(
                        ErrorCode::ResourceLimit,
                        "Project identities exhausted",
                        false,
                    )
                })?;
                let id = ProjectId(compiles.next_project);
                compiles.projects.insert(root_file, id);
                id
            };
            let generation = *compiles
                .generations
                .entry(next_project)
                .or_insert(ProjectGeneration(1));
            (next_project, generation)
        };
        self.begin_compile(
            session,
            epoch,
            &project_id.0.to_string(),
            &generation.0.to_string(),
            &root_file.0 .0.to_string(),
            profile,
        )
    }

    pub(crate) fn capabilities(&self) -> Vec<String> {
        let mut capabilities = lino_protocol::CAPABILITIES
            .iter()
            .map(|value| (*value).to_owned())
            .collect::<Vec<_>>();
        if self.compiler.is_available() {
            capabilities.push("latex-compile".into());
        }
        capabilities
    }

    pub fn begin_compile(
        self: &Arc<Self>,
        session: &str,
        epoch: &str,
        project_id: &str,
        project_generation: &str,
        root_file_ref: &str,
        profile: WireProfile,
    ) -> Result<Arc<CompileJob>, WireError> {
        let session_id = SessionId(number(session)?);
        let expected_epoch = EditorEpoch(number(epoch)?);
        let project_id = ProjectId(number(project_id)?);
        let generation = ProjectGeneration(number(project_generation)?);
        let root_file = RootFileRef(FileRef(number(root_file_ref)?));
        let info = self.info(session_id)?;
        if info.epoch != expected_epoch {
            return Err(error(ErrorCode::OldEpoch, "编辑视图已变化。", false));
        }
        if info.kind != DocumentKind::Latex {
            return Err(error(
                ErrorCode::UnsupportedOperation,
                "This operation requires a LaTeX document.",
                false,
            ));
        }
        if info.file != Some(root_file.0) {
            return Err(error(
                ErrorCode::InvalidMessage,
                "编译 root 与当前文档不一致。",
                false,
            ));
        }
        let profile = match profile {
            WireProfile::LatexmkXelatex => CompileProfile::LatexmkXelatex,
        };
        let mut compiles = self
            .compiles
            .lock()
            .map_err(|_| error(ErrorCode::Internal, "Compile registry poisoned", false))?;
        compiles
            .jobs
            .retain(|job| job.upgrade().is_some_and(|job| job.running()));
        if compiles.jobs.len() >= 4 {
            return Err(error(
                ErrorCode::Busy,
                "Four LaTeX compilations are already running.",
                true,
            ));
        }
        compiles
            .generations
            .entry(project_id)
            .and_modify(|current| {
                if generation > *current {
                    *current = generation;
                }
            })
            .or_insert(generation);
        compiles.next = compiles.next.checked_add(1).ok_or_else(|| {
            error(
                ErrorCode::ResourceLimit,
                "Compile identities exhausted",
                false,
            )
        })?;
        let job = Arc::new(CompileJob {
            id: JobId(compiles.next),
            runtime: self.clone(),
            request: CompileRequest::fixed_snapshot(
                JobId(compiles.next),
                session_id,
                expected_epoch,
                project_id,
                root_file,
                generation,
                profile,
                info.snapshot,
            ),
            state: Mutex::default(),
            cancelled: Arc::new(AtomicBool::new(false)),
            outcome: Mutex::default(),
            error: Mutex::default(),
        });
        compiles.jobs.push(Arc::downgrade(&job));
        Ok(job)
    }
}

impl CompileJob {
    pub fn request(&self) -> &CompileRequest {
        &self.request
    }

    pub fn running(&self) -> bool {
        self.state
            .lock()
            .map(|state| {
                !matches!(
                    state.state(),
                    CompileJobState::Succeeded
                        | CompileJobState::Failed
                        | CompileJobState::Cancelled
                )
            })
            .unwrap_or(false)
    }

    pub fn cancel(&self) -> bool {
        self.cancelled.store(true, Ordering::Release);
        self.state
            .lock()
            .map(|mut state| state.cancel())
            .unwrap_or(false)
    }

    /// Run one fixed snapshot. The host should call this away from the UI
    /// thread; all identity checks remain valid if the document changes while
    /// the compiler is running.
    pub fn run(&self) -> Result<(), WireError> {
        {
            let mut state = self
                .state
                .lock()
                .map_err(|_| error(ErrorCode::Internal, "Compile state poisoned", false))?;
            if !state.begin_preparing() {
                return Err(error(
                    ErrorCode::UnsupportedOperation,
                    "Compile job already started or cancelled.",
                    false,
                ));
            }
        }
        if self.cancelled.load(Ordering::Acquire) || !self.is_current().unwrap_or(false) {
            self.cancel();
            return Ok(());
        }
        {
            let mut state = self
                .state
                .lock()
                .map_err(|_| error(ErrorCode::Internal, "Compile state poisoned", false))?;
            if !state.begin_compiling() {
                return Ok(());
            }
        }
        let result = self
            .runtime
            .compiler
            .compile(&self.request, &self.cancelled);
        match result {
            Ok(outcome) => {
                let success = matches!(outcome, CompileOutcome::Succeeded(_));
                if let CompileOutcome::Succeeded(output) = &outcome {
                    if self.is_current().unwrap_or(false) {
                        self.runtime
                            .compiles
                            .lock()
                            .map_err(|_| {
                                error(ErrorCode::Internal, "Compile registry poisoned", false)
                            })?
                            .latest
                            .insert(self.request.project_id, output.clone());
                    }
                }
                *self
                    .outcome
                    .lock()
                    .map_err(|_| error(ErrorCode::Internal, "Compile result poisoned", false))? =
                    Some(outcome);
                self.state
                    .lock()
                    .map_err(|_| error(ErrorCode::Internal, "Compile state poisoned", false))?
                    .finish(success);
            }
            Err(compile_error) => {
                if matches!(compile_error, CompileError::Cancelled) {
                    self.cancel();
                } else {
                    *self.error.lock().map_err(|_| {
                        error(ErrorCode::Internal, "Compile error poisoned", false)
                    })? = Some(compile_error);
                    self.state
                        .lock()
                        .map_err(|_| error(ErrorCode::Internal, "Compile state poisoned", false))?
                        .finish(false);
                }
            }
        }
        Ok(())
    }

    pub fn status(&self) -> Result<CompileStatus, WireError> {
        let state = self
            .state
            .lock()
            .map_err(|_| error(ErrorCode::Internal, "Compile state poisoned", false))?
            .state();
        let outcome = self
            .outcome
            .lock()
            .map_err(|_| error(ErrorCode::Internal, "Compile result poisoned", false))?;
        let error_value = self
            .error
            .lock()
            .map_err(|_| error(ErrorCode::Internal, "Compile error poisoned", false))?;
        let latest = self
            .runtime
            .compiles
            .lock()
            .map_err(|_| error(ErrorCode::Internal, "Compile registry poisoned", false))?
            .latest
            .get(&self.request.project_id)
            .cloned();
        let (artifact_ref, compiler, log, diagnostics) = match outcome.as_ref() {
            Some(CompileOutcome::Succeeded(output)) if self.is_current().unwrap_or(false) => (
                Some(output.artifact.0.to_string()),
                Some(output.compiler.clone()),
                Some(output.log.clone()),
                output.diagnostics.clone(),
            ),
            Some(CompileOutcome::Succeeded(_)) => latest
                .as_ref()
                .map(|output| {
                    (
                        Some(output.artifact.0.to_string()),
                        Some(output.compiler.clone()),
                        Some(output.log.clone()),
                        output.diagnostics.clone(),
                    )
                })
                .unwrap_or_else(|| (None, None, None, Vec::new())),
            Some(CompileOutcome::Failed { log, diagnostics }) => (
                latest.as_ref().map(|output| output.artifact.0.to_string()),
                latest.as_ref().map(|output| output.compiler.clone()),
                Some(log.clone()),
                diagnostics.clone(),
            ),
            None => (
                latest.as_ref().map(|output| output.artifact.0.to_string()),
                latest.as_ref().map(|output| output.compiler.clone()),
                error_value.as_ref().map(compile_error_message),
                Vec::new(),
            ),
        };
        Ok(CompileStatus {
            job_id: self.id.0.to_string(),
            session_id: self.request.owner_session.0.to_string(),
            project_id: self.request.project_id.0.to_string(),
            root_file_ref: self.request.root_file.0 .0.to_string(),
            source_revision: self.request.source_revision.value().to_string(),
            project_generation: self.request.project_generation.0.to_string(),
            profile: WireProfile::LatexmkXelatex,
            state: wire_state(state),
            artifact_ref,
            stale: !self.is_current().unwrap_or(false) || state == CompileJobState::Failed,
            compiler,
            log,
            diagnostics: diagnostics.into_iter().map(wire_diagnostic).collect(),
        })
    }

    pub fn pdf(&self) -> Result<Vec<u8>, WireError> {
        let outcome = self
            .outcome
            .lock()
            .map_err(|_| error(ErrorCode::Internal, "Compile result poisoned", false))?;
        match outcome.as_ref() {
            Some(CompileOutcome::Succeeded(output)) if self.is_current().unwrap_or(false) => {
                Ok(output.pdf.clone())
            }
            _ => self
                .runtime
                .compiles
                .lock()
                .map_err(|_| error(ErrorCode::Internal, "Compile registry poisoned", false))?
                .latest
                .get(&self.request.project_id)
                .map(|output| output.pdf.clone())
                .ok_or_else(|| error(ErrorCode::NotFound, "PDF artifact is not available.", false)),
        }
    }

    fn is_current(&self) -> Result<bool, WireError> {
        let info = self.runtime.info(self.request.owner_session)?;
        Ok(info.epoch == self.request.owner_epoch
            && info.kind == DocumentKind::Latex
            && info.file == Some(self.request.root_file.0)
            && info.snapshot.revision() == self.request.source_revision
            && self
                .runtime
                .compiles
                .lock()
                .map_err(|_| error(ErrorCode::Internal, "Compile registry poisoned", false))?
                .generations
                .get(&self.request.project_id)
                == Some(&self.request.project_generation))
    }
}

fn wire_state(state: CompileJobState) -> WireState {
    match state {
        CompileJobState::Queued => WireState::Queued,
        CompileJobState::Preparing => WireState::Preparing,
        CompileJobState::Compiling => WireState::Compiling,
        CompileJobState::Succeeded => WireState::Succeeded,
        CompileJobState::Failed => WireState::Failed,
        CompileJobState::Cancelled => WireState::Cancelled,
    }
}

fn wire_diagnostic(value: CompileDiagnostic) -> lino_protocol::CompileDiagnostic {
    lino_protocol::CompileDiagnostic {
        file: value.file,
        line: value.line,
        column: value.column,
        severity: match value.severity {
            lino_application::compile::CompileDiagnosticSeverity::Error => {
                CompileDiagnosticSeverity::Error
            }
            lino_application::compile::CompileDiagnosticSeverity::Warning => {
                CompileDiagnosticSeverity::Warning
            }
            lino_application::compile::CompileDiagnosticSeverity::Info => {
                CompileDiagnosticSeverity::Info
            }
        },
        message: value.message,
    }
}

fn compile_error_message(value: &CompileError) -> String {
    match value {
        CompileError::CompilerUnavailable => "latexmk is not available".into(),
        CompileError::Cancelled => "Compilation cancelled".into(),
        CompileError::TimedOut => "Compilation timed out".into(),
        CompileError::OutputLimit => "Compilation output exceeded the limit".into(),
        CompileError::Io(message) => message.clone(),
    }
}
