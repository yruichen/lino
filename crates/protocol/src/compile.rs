use serde::{Deserialize, Serialize};
use ts_rs::TS;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize, TS)]
#[serde(rename_all = "snake_case")]
pub enum CompileProfile {
    LatexmkXelatex,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize, TS)]
#[serde(rename_all = "snake_case")]
pub enum CompileJobState {
    Queued,
    Preparing,
    Compiling,
    Succeeded,
    Failed,
    Cancelled,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize, TS)]
#[serde(rename_all = "snake_case")]
pub enum CompileDiagnosticSeverity {
    Error,
    Warning,
    Info,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize, TS)]
#[serde(deny_unknown_fields)]
pub struct CompileDiagnostic {
    pub file: Option<String>,
    pub line: Option<u32>,
    pub column: Option<u32>,
    pub severity: CompileDiagnosticSeverity,
    pub message: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize, TS)]
#[serde(deny_unknown_fields)]
pub struct CompileStatus {
    pub job_id: String,
    pub session_id: String,
    pub project_id: String,
    pub root_file_ref: String,
    pub source_revision: String,
    pub project_generation: String,
    pub profile: CompileProfile,
    pub state: CompileJobState,
    pub artifact_ref: Option<String>,
    pub stale: bool,
    pub compiler: Option<String>,
    pub log: Option<String>,
    pub diagnostics: Vec<CompileDiagnostic>,
}
