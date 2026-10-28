//! Exactly one terminal result, with an explicit irreversible commit boundary.

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct JobId(pub u64);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CompileJobState {
    Queued,
    Preparing,
    Compiling,
    Succeeded,
    Failed,
    Cancelled,
}

pub struct CompileJobLifecycle {
    state: CompileJobState,
}

impl Default for CompileJobLifecycle {
    fn default() -> Self {
        Self {
            state: CompileJobState::Queued,
        }
    }
}

impl CompileJobLifecycle {
    pub fn state(&self) -> CompileJobState {
        self.state
    }

    pub fn begin_preparing(&mut self) -> bool {
        if self.state != CompileJobState::Queued {
            return false;
        }
        self.state = CompileJobState::Preparing;
        true
    }

    pub fn begin_compiling(&mut self) -> bool {
        if !matches!(self.state, CompileJobState::Preparing) {
            return false;
        }
        self.state = CompileJobState::Compiling;
        true
    }

    pub fn finish(&mut self, success: bool) -> bool {
        if !matches!(self.state, CompileJobState::Compiling) {
            return false;
        }
        self.state = if success {
            CompileJobState::Succeeded
        } else {
            CompileJobState::Failed
        };
        true
    }

    pub fn cancel(&mut self) -> bool {
        if matches!(
            self.state,
            CompileJobState::Succeeded | CompileJobState::Failed | CompileJobState::Cancelled
        ) {
            return false;
        }
        self.state = CompileJobState::Cancelled;
        true
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum JobState {
    Running,
    Committing,
    Succeeded,
    Failed,
    Cancelled,
}
pub struct JobLifecycle {
    state: JobState,
}
impl Default for JobLifecycle {
    fn default() -> Self {
        Self {
            state: JobState::Running,
        }
    }
}
impl JobLifecycle {
    pub fn state(&self) -> JobState {
        self.state
    }
    pub fn cancel(&mut self) -> bool {
        if self.state != JobState::Running {
            return false;
        }
        self.state = JobState::Cancelled;
        true
    }
    pub fn begin_commit(&mut self) -> Result<(), &'static str> {
        if self.state != JobState::Running {
            return Err("Export is cancelled or already finished");
        }
        self.state = JobState::Committing;
        Ok(())
    }
    pub fn finish(&mut self, success: bool) {
        if self.state == JobState::Committing {
            self.state = if success {
                JobState::Succeeded
            } else {
                JobState::Failed
            };
        }
    }
}
