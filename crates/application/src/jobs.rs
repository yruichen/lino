//! Exactly one terminal result, with an explicit irreversible commit boundary.
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
