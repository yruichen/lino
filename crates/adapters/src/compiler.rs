use lino_application::{
    compile::{
        CompileDiagnostic, CompileDiagnosticSeverity, CompileError, CompileOutcome, CompileRequest,
    },
    ports::CompilerPort,
};
use regex::Regex;
use std::{
    fs::{self, File},
    io::{self, Read},
    path::Path,
    process::{Command, Stdio},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc,
    },
    thread,
    time::{Duration, Instant},
};
use tempfile::TempDir;

const MAX_PROJECT_FILES: usize = 10_000;
const MAX_PROJECT_BYTES: u64 = 256 * 1024 * 1024;
const MAX_LOG_BYTES: usize = 4 * 1024 * 1024;
const MAX_COMPILE_TIME: Duration = Duration::from_secs(10 * 60);

pub struct LatexCompiler {
    storage: Arc<crate::storage::FileStorage>,
    next_artifact: AtomicU64,
}

impl LatexCompiler {
    pub fn new(storage: Arc<crate::storage::FileStorage>) -> Self {
        Self {
            storage,
            next_artifact: AtomicU64::new(1),
        }
    }

    fn next_artifact(&self) -> Result<lino_application::compile::ArtifactRef, CompileError> {
        self.next_artifact
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |value| {
                value.checked_add(1)
            })
            .map(lino_application::compile::ArtifactRef)
            .map_err(|_| CompileError::OutputLimit)
    }

    fn prepare_tree(&self, source_path: &Path, target: &Path) -> Result<(), CompileError> {
        let parent = source_path
            .parent()
            .ok_or_else(|| CompileError::Io("LaTeX root has no parent directory".into()))?;
        let mut files = 0;
        let mut bytes = 0;
        copy_tree(parent, target, &mut files, &mut bytes).map_err(map_io)?;
        Ok(())
    }
}

impl CompilerPort for LatexCompiler {
    fn is_available(&self) -> bool {
        Command::new("latexmk")
            .arg("-version")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|status| status.success())
    }

    fn compile(
        &self,
        request: &CompileRequest,
        cancelled: &AtomicBool,
    ) -> Result<CompileOutcome, CompileError> {
        if cancelled.load(Ordering::Relaxed) {
            return Err(CompileError::Cancelled);
        }

        let source_path = self
            .storage
            .path(request.root_file.0)
            .map_err(|error| CompileError::Io(error.to_string()))?;
        let root_name = source_path
            .file_name()
            .ok_or_else(|| CompileError::Io("LaTeX root has no filename".into()))?
            .to_owned();
        let temp = TempDir::new().map_err(map_io)?;
        self.prepare_tree(&source_path, temp.path())?;
        fs::write(temp.path().join(&root_name), request.source.text()).map_err(map_io)?;

        let log_path = temp.path().join("lino-compile.log");
        let stdout = File::create(&log_path).map_err(map_io)?;
        let stderr = stdout.try_clone().map_err(map_io)?;
        let output_dir = temp.path().to_string_lossy().into_owned();
        let root_name = root_name.to_string_lossy().into_owned();
        let mut child = Command::new("latexmk")
            .args([
                "-xelatex",
                "-interaction=nonstopmode",
                "-halt-on-error",
                "-file-line-error",
                "-no-shell-escape",
            ])
            .arg(format!("-outdir={output_dir}"))
            .arg(&root_name)
            .current_dir(temp.path())
            .stdin(Stdio::null())
            .stdout(Stdio::from(stdout))
            .stderr(Stdio::from(stderr))
            .spawn()
            .map_err(|error| match error.kind() {
                io::ErrorKind::NotFound => CompileError::CompilerUnavailable,
                _ => map_io(error),
            })?;

        let started = Instant::now();
        loop {
            if cancelled.load(Ordering::Relaxed) {
                let _ = child.kill();
                let _ = child.wait();
                return Err(CompileError::Cancelled);
            }
            if started.elapsed() >= MAX_COMPILE_TIME {
                let _ = child.kill();
                let _ = child.wait();
                return Err(CompileError::TimedOut);
            }
            if child.try_wait().map_err(map_io)?.is_some() {
                break;
            }
            thread::sleep(Duration::from_millis(40));
        }

        let mut log = String::new();
        File::open(&log_path)
            .map_err(map_io)?
            .take(MAX_LOG_BYTES as u64 + 1)
            .read_to_string(&mut log)
            .map_err(map_io)?;
        if log.len() > MAX_LOG_BYTES {
            log.truncate(MAX_LOG_BYTES);
            return Err(CompileError::OutputLimit);
        }
        let diagnostics = parse_diagnostics(&log);
        let pdf_path = temp
            .path()
            .join(Path::new(&root_name).with_extension("pdf"));
        let status = child.wait().map_err(map_io)?;
        let pdf = fs::read(&pdf_path).ok();
        let valid_pdf = pdf
            .as_deref()
            .is_some_and(|bytes| bytes.starts_with(b"%PDF-"));
        if !status.success() || !valid_pdf {
            return Ok(CompileOutcome::Failed { log, diagnostics });
        }

        Ok(CompileOutcome::Succeeded(
            lino_application::compile::CompileOutput {
                artifact: self.next_artifact()?,
                pdf: pdf.expect("validated PDF is present"),
                log,
                diagnostics,
                compiler: "latexmk + xelatex".into(),
            },
        ))
    }
}

fn map_io(error: io::Error) -> CompileError {
    CompileError::Io(error.to_string())
}

fn copy_tree(source: &Path, target: &Path, files: &mut usize, bytes: &mut u64) -> io::Result<()> {
    fs::create_dir_all(target)?;
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let file_type = entry.file_type()?;
        let from = entry.path();
        let to = target.join(entry.file_name());
        if file_type.is_symlink() {
            continue;
        }
        if file_type.is_dir() {
            copy_tree(&from, &to, files, bytes)?;
            continue;
        }
        if !file_type.is_file() {
            continue;
        }
        *files += 1;
        if *files > MAX_PROJECT_FILES {
            return Err(io::Error::other("LaTeX project has too many files"));
        }
        let size = entry.metadata()?.len();
        *bytes = bytes.saturating_add(size);
        if *bytes > MAX_PROJECT_BYTES {
            return Err(io::Error::other("LaTeX project is too large"));
        }
        fs::copy(from, to)?;
    }
    Ok(())
}

fn parse_diagnostics(log: &str) -> Vec<CompileDiagnostic> {
    let location = Regex::new(
        r"^(?P<file>[^:\n]+):(?P<line>[0-9]+)(?::(?P<column>[0-9]+))?:\s*(?P<message>.*)$",
    )
    .expect("static diagnostic expression");
    log.lines()
        .filter_map(|line| {
            let captures = location.captures(line)?;
            let message = captures.name("message")?.as_str().trim();
            let severity = if message.to_ascii_lowercase().contains("warning") {
                CompileDiagnosticSeverity::Warning
            } else {
                CompileDiagnosticSeverity::Error
            };
            Some(CompileDiagnostic {
                file: Some(captures.name("file")?.as_str().to_owned()),
                line: captures
                    .name("line")
                    .and_then(|value| value.as_str().parse().ok()),
                column: captures
                    .name("column")
                    .and_then(|value| value.as_str().parse().ok()),
                severity,
                message: message.to_owned(),
            })
        })
        .collect()
}
