use crate::{
    jobs::JobId,
    projects::{ProjectGeneration, ProjectId, RootFileRef},
};
use lino_document::{EditorEpoch, Revision, SessionId, Snapshot};

/// The first profile is deliberately fixed: no arbitrary compiler arguments
/// or shell-escape settings cross the application boundary.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Default)]
pub enum CompileProfile {
    #[default]
    LatexmkXelatex,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct ArtifactRef(pub u64);

#[derive(Clone, Debug)]
pub struct CompileRequest {
    pub job_id: JobId,
    pub owner_session: SessionId,
    pub owner_epoch: EditorEpoch,
    pub project_id: ProjectId,
    pub root_file: RootFileRef,
    pub source_revision: Revision,
    pub project_generation: ProjectGeneration,
    pub profile: CompileProfile,
    pub source: Snapshot,
}

impl CompileRequest {
    // The constructor keeps every identity explicit so a compile cannot
    // accidentally inherit a mutable session or project field.
    #[allow(clippy::too_many_arguments)]
    pub fn fixed_snapshot(
        job_id: JobId,
        owner_session: SessionId,
        owner_epoch: EditorEpoch,
        project_id: ProjectId,
        root_file: RootFileRef,
        project_generation: ProjectGeneration,
        profile: CompileProfile,
        source: Snapshot,
    ) -> Self {
        Self {
            job_id,
            owner_session,
            owner_epoch,
            project_id,
            root_file,
            source_revision: source.revision(),
            project_generation,
            profile,
            source,
        }
    }

    pub fn revision(&self) -> Revision {
        self.source_revision
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CompileDiagnosticSeverity {
    Error,
    Warning,
    Info,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CompileDiagnostic {
    pub file: Option<String>,
    pub line: Option<u32>,
    pub column: Option<u32>,
    pub severity: CompileDiagnosticSeverity,
    pub message: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CompileOutput {
    pub artifact: ArtifactRef,
    pub pdf: Vec<u8>,
    pub log: String,
    pub diagnostics: Vec<CompileDiagnostic>,
    pub compiler: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CompileOutcome {
    Succeeded(CompileOutput),
    Failed {
        log: String,
        diagnostics: Vec<CompileDiagnostic>,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CompileError {
    CompilerUnavailable,
    Cancelled,
    TimedOut,
    OutputLimit,
    Io(String),
}

#[cfg(test)]
mod tests {
    use super::*;
    use lino_document::{FileRef, SessionId};

    #[test]
    fn compile_request_captures_an_immutable_revision_and_profile() {
        let source = Snapshot::new("\\documentclass{article}\n".to_owned()).unwrap();
        let request = CompileRequest::fixed_snapshot(
            JobId(3),
            SessionId(4),
            EditorEpoch(8),
            ProjectId(5),
            RootFileRef(FileRef(6)),
            ProjectGeneration(7),
            CompileProfile::LatexmkXelatex,
            source.clone(),
        );
        assert_eq!(request.revision(), source.revision());
        assert_eq!(request.owner_epoch, EditorEpoch(8));
        assert_eq!(request.project_generation, ProjectGeneration(7));
        assert_eq!(request.profile, CompileProfile::LatexmkXelatex);
        assert_eq!(request.source.text(), "\\documentclass{article}\n");
    }
}
