//! Recovery I/O has one serialization gate, independent of the document mutex.
//! Edits continue while a fixed snapshot is written. Close reserves the session
//! before retiring its copy, so queued checkpoints cannot resurrect a discard.
use crate::{
    dispatch::{close_intent, document_error, error, number, storage_error, to_opened},
    DocumentRuntime,
};
use lino_application::{
    documents::{CloseIntent, DocumentInfo, Documents},
    recovery::{RecoveryPort, RecoverySnapshot},
};
use lino_document::{EditorEpoch, Revision, SessionId};
use lino_protocol::{ErrorCode, OpenedDocument, RecoveryEntry, WireError};
use std::{collections::HashMap, path::Path, sync::MutexGuard};

struct Draft {
    key: String,
    durable_revision: Option<Revision>,
    label: Option<String>,
    format: lino_document::TextFormat,
}
#[derive(Default)]
pub(crate) struct RecoveryState {
    store: Option<Box<dyn RecoveryPort>>,
    configured_path: Option<std::path::PathBuf>,
    drafts: HashMap<SessionId, Draft>,
}
impl RecoveryState {
    fn store(&mut self) -> Result<&mut (dyn RecoveryPort + '_), WireError> {
        match self.store.as_mut() {
            Some(store) => Ok(store.as_mut()),
            None => Err(error(
                ErrorCode::UnsupportedOperation,
                "恢复存储未初始化。",
                false,
            )),
        }
    }
    fn retire(&mut self, id: SessionId) -> Result<(), WireError> {
        if let Some(draft) = self.drafts.get_mut(&id) {
            // Deletion may succeed even when subsequent directory sync fails.
            // A retry must rewrite the copy, never trust a now-missing record.
            draft.durable_revision = None;
            let key = draft.key.clone();
            self.store()?.retire(&key).map_err(storage_error)?;
            self.drafts.remove(&id);
        }
        Ok(())
    }
    fn write(&mut self, info: &DocumentInfo) -> Result<bool, WireError> {
        if self.drafts.get(&info.id).is_some_and(|draft| {
            draft.durable_revision == Some(info.snapshot.revision())
                && draft.label == info.label
                && draft.format == info.format
        }) {
            return Ok(true);
        }
        let key = self.drafts.get(&info.id).map(|draft| draft.key.clone());
        let (key, durable) = self
            .store()?
            .write(
                key.as_deref(),
                &RecoverySnapshot {
                    snapshot: info.snapshot.clone(),
                    format: info.format,
                    label: info.label.clone(),
                },
            )
            .map_err(storage_error)?;
        self.drafts.insert(
            info.id,
            Draft {
                key,
                durable_revision: durable.then_some(info.snapshot.revision()),
                label: info.label.clone(),
                format: info.format,
            },
        );
        Ok(durable)
    }
}
impl DocumentRuntime {
    fn recovery_lock(&self) -> Result<MutexGuard<'_, RecoveryState>, WireError> {
        self.recovery
            .lock()
            .map_err(|_| error(ErrorCode::Internal, "恢复状态锁异常。", false))
    }
    pub fn configure_recovery(&self, path: &Path) -> Result<(), WireError> {
        let mut recovery = self.recovery_lock()?;
        if recovery.configured_path.as_deref() == Some(path) {
            return Ok(());
        }
        if recovery.store.is_some() {
            return Err(error(ErrorCode::Busy, "恢复存储已初始化。", false));
        }
        recovery.store = Some(Box::new(
            lino_adapters::recovery::FileRecovery::open(path).map_err(storage_error)?,
        ));
        recovery.configured_path = Some(path.to_path_buf());
        Ok(())
    }
    /// Injection point for deterministic storage failure/concurrency tests.
    pub fn set_recovery_port(&self, port: Box<dyn RecoveryPort>) -> Result<(), WireError> {
        let mut recovery = self.recovery_lock()?;
        if recovery.store.is_some() {
            return Err(error(ErrorCode::Busy, "恢复存储已初始化。", false));
        }
        recovery.store = Some(port);
        Ok(())
    }
    pub fn list_recoveries(&self) -> Result<Vec<RecoveryEntry>, WireError> {
        let mut recovery = self.recovery_lock()?;
        let entries = recovery.store()?.list().map_err(storage_error)?;
        Ok(entries
            .into_iter()
            .filter(|entry| !recovery.drafts.values().any(|draft| draft.key == entry.key))
            .map(|entry| RecoveryEntry {
                key: entry.key,
                label: entry.label,
                problem: entry.problem,
            })
            .collect())
    }
    pub fn discard_recovery(&self, key: &str) -> Result<(), WireError> {
        let mut recovery = self.recovery_lock()?;
        if recovery.drafts.values().any(|draft| draft.key == key) {
            return Err(error(
                ErrorCode::Busy,
                "恢复副本属于正在编辑的文档。",
                false,
            ));
        }
        recovery.store()?.retire(key).map_err(storage_error)
    }
    pub(crate) fn checkpoint(
        &self,
        id: SessionId,
        epoch: EditorEpoch,
    ) -> Result<(String, bool), WireError> {
        let mut recovery = self.recovery_lock()?;
        let info = self.info(id)?;
        if info.epoch != epoch {
            return Err(error(ErrorCode::OldEpoch, "编辑写入租约已失效。", false));
        }
        let durable = if info.dirty || !info.saved_durable {
            recovery.write(&info)?
        } else {
            recovery.retire(id)?;
            true
        };
        Ok((info.snapshot.revision().value().to_string(), durable))
    }
    fn transition_in<T>(
        &self,
        recovery: &mut RecoveryState,
        replace: Option<CloseIntent>,
        action: impl FnOnce(
            &mut Documents,
            Option<CloseIntent>,
        ) -> Result<T, lino_application::documents::DocumentError>,
    ) -> Result<T, WireError> {
        let mut keep_copy = None;
        if let Some(intent) = &replace {
            self.lock()?.begin_close(intent).map_err(document_error)?;
            let info = self.info(intent.session)?;
            let protection = if recovery.store.is_some() && !info.saved_durable && !intent.discard {
                recovery.write(&info).and_then(|durable| {
                    if durable {
                        keep_copy = Some(intent.session);
                        Ok(())
                    } else {
                        Err(error(
                            ErrorCode::Io,
                            "原文件与恢复副本均未确认持久化；文档仍保持打开。",
                            true,
                        ))
                    }
                })
            } else {
                recovery.retire(intent.session)
            };
            if let Err(error) = protection {
                self.lock()?.cancel_close(intent.session);
                return Err(error);
            }
        }
        let old = replace.as_ref().map(|intent| intent.session);
        let result = action(&mut *self.lock()?, replace).map_err(document_error);
        if result.is_ok() {
            if let Some(id) = keep_copy {
                recovery.drafts.remove(&id);
            }
        }
        if result.is_err() {
            if let Some(id) = old {
                self.lock()?.cancel_close(id);
                // The old document remains editable if a replacement fails. Recreate
                // its protection if retirement already succeeded, and surface failure.
                let info = self.info(id)?;
                if recovery.store.is_some() && (info.dirty || !info.saved_durable) {
                    recovery.write(&info)?;
                }
            }
        }
        result
    }
    pub(crate) fn transition<T>(
        &self,
        replace: Option<CloseIntent>,
        action: impl FnOnce(
            &mut Documents,
            Option<CloseIntent>,
        ) -> Result<T, lino_application::documents::DocumentError>,
    ) -> Result<T, WireError> {
        self.transition_in(&mut *self.recovery_lock()?, replace, action)
    }
    pub fn restore_recovery(
        &self,
        key: &str,
        replace: Option<lino_protocol::CloseIntent>,
    ) -> Result<OpenedDocument, WireError> {
        let replace = replace.map(close_intent).transpose()?;
        let previous = self.previous_file(&replace)?;
        let mut recovery = self.recovery_lock()?;
        if recovery.drafts.values().any(|draft| draft.key == key) {
            return Err(error(ErrorCode::Busy, "恢复副本正在编辑。", false));
        }
        let recovered = recovery.store()?.read(key).map_err(storage_error)?;
        let info = self.transition_in(&mut recovery, replace, |docs, replace| {
            docs.restore(recovered, replace)
        })?;
        recovery.drafts.insert(
            info.id,
            Draft {
                key: key.to_owned(),
                durable_revision: Some(info.snapshot.revision()),
                label: info.label.clone(),
                format: info.format,
            },
        );
        drop(recovery);
        self.release_unused(previous);
        Ok(to_opened(info))
    }
    pub fn reattach_document(&self, session_id: &str) -> Result<OpenedDocument, WireError> {
        let recovery = self.recovery_lock()?;
        let (info, abandoned) = self
            .lock()?
            .reattach(SessionId(number(session_id)?))
            .map_err(document_error)?;
        drop(recovery);
        self.release_unused(abandoned);
        Ok(to_opened(info))
    }
    pub(crate) fn close_document(
        &self,
        session_id: String,
        epoch: String,
        revision: String,
        discard: bool,
    ) -> Result<(), WireError> {
        let id = SessionId(number(&session_id)?);
        let file = self.info(id)?.file;
        let intent = CloseIntent {
            session: id,
            epoch: EditorEpoch(number(&epoch)?),
            revision: number(&revision)?,
            discard,
        };
        self.transition(Some(intent), |docs, intent| {
            let intent = intent.unwrap();
            docs.close(
                intent.session,
                intent.epoch,
                intent.revision,
                intent.discard,
            )
        })?;
        self.release_unused(file);
        Ok(())
    }
}

impl DocumentRuntime {
    pub fn abandon_document(&self, session_id: &str) -> Result<(), WireError> {
        let id = SessionId(number(session_id)?);
        let mut recovery = self.recovery_lock()?;
        let files = self.lock()?.abandon(id).map_err(document_error)?;
        // Keep the on-disk draft, making it selectable on the next recovery.
        recovery.drafts.remove(&id);
        drop(recovery);
        for file in files {
            self.release_unused(Some(file));
        }
        Ok(())
    }
}
