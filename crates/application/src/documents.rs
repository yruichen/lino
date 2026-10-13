use crate::ports::{DiskVersion, LoadedFile, StorageCommit, StorageError};
use open_typora_document::{
    EditorEpoch, FileRef, ModelError, Revision, SessionId, Snapshot, TextChange, TextFormat,
};
use std::collections::HashMap;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DocumentError {
    UnknownSession,
    OldEpoch,
    SequenceGap,
    StaleRevision,
    DuplicateMismatch,
    Busy,
    NotSaved,
    InvalidTicket,
    ResourceLimit,
    Model(ModelError),
    Storage(StorageError),
}

#[derive(Clone, Debug)]
pub struct DocumentInfo {
    pub id: SessionId,
    pub epoch: EditorEpoch,
    pub snapshot: Snapshot,
    pub saved_revision: Option<Revision>,
    pub saved_durable: bool,
    pub file: Option<FileRef>,
    pub label: Option<String>,
    pub dirty: bool,
    pub saving: bool,
    pub format: TextFormat,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApplyBatch {
    pub epoch: EditorEpoch,
    pub sequence: u64,
    pub base_revision: u64,
    pub changes: Vec<TextChange>,
}

#[derive(Clone, Debug)]
pub struct ApplyAck {
    pub sequence: u64,
    pub revision: Revision,
}

#[derive(Clone, Debug)]
pub struct SaveTarget {
    pub file: FileRef,
    pub expected: Option<DiskVersion>,
    pub label: String,
}

#[derive(Clone, Debug)]
pub struct SaveTicket {
    pub id: u64,
    pub session: SessionId,
    pub request: StorageCommit,
    pub label: String,
}

#[derive(Clone, Debug)]
pub struct SaveReceipt {
    pub ticket: u64,
    pub revision: Revision,
    pub durable: bool,
}

#[derive(Clone, Debug)]
pub struct CloseIntent {
    pub session: SessionId,
    pub epoch: EditorEpoch,
    pub revision: u64,
    pub discard: bool,
}

struct Session {
    snapshot: Snapshot,
    epoch: EditorEpoch,
    format: TextFormat,
    saved_revision: Option<Revision>,
    saved_durable: bool,
    binding: Option<SaveTarget>,
    last_batch: Option<(ApplyBatch, ApplyAck)>,
    pending_save: Option<(SaveTicket, bool)>,
    last_receipt: Option<SaveReceipt>,
    transitioning: bool,
    recovered_label: Option<String>,
    recovered: bool,
}

#[derive(Default)]
pub struct Documents {
    sessions: HashMap<SessionId, Session>,
    next_session: u64,
    next_ticket: u64,
}

impl Documents {
    fn create(
        &mut self,
        text: String,
        format: TextFormat,
        binding: Option<SaveTarget>,
        replace: Option<CloseIntent>,
    ) -> Result<DocumentInfo, DocumentError> {
        let snapshot = Snapshot::new(text).map_err(DocumentError::Model)?;
        if let Some(intent) = &replace {
            self.validate_close(intent)?;
        }
        let replaced = replace.as_ref().map(|intent| intent.session);
        if self.sessions.len() - usize::from(replaced.is_some()) >= 32 {
            return Err(DocumentError::ResourceLimit);
        }
        if let Some(target) = &binding {
            if self.sessions.iter().any(|(id, session)| {
                Some(*id) != replaced
                    && session.binding.as_ref().map(|t| t.file) == Some(target.file)
            }) {
                return Err(DocumentError::Busy);
            }
        }
        self.next_session = self
            .next_session
            .checked_add(1)
            .ok_or(DocumentError::ResourceLimit)?;
        let id = SessionId(self.next_session);
        let saved_revision = binding.as_ref().map(|_| snapshot.revision());
        self.sessions.insert(
            id,
            Session {
                snapshot,
                epoch: EditorEpoch(1),
                format,
                saved_revision,
                saved_durable: true,
                binding,
                last_batch: None,
                pending_save: None,
                last_receipt: None,
                transitioning: false,
                recovered_label: None,
                recovered: false,
            },
        );
        if let Some(old) = replaced {
            self.sessions.remove(&old);
        }
        self.info(id)
    }
    pub fn new_document(
        &mut self,
        replace: Option<CloseIntent>,
    ) -> Result<DocumentInfo, DocumentError> {
        self.create(String::new(), TextFormat::default(), None, replace)
    }
    pub fn open(
        &mut self,
        file: FileRef,
        loaded: LoadedFile,
        replace: Option<CloseIntent>,
    ) -> Result<DocumentInfo, DocumentError> {
        self.create(
            loaded.text,
            loaded.format,
            Some(SaveTarget {
                file,
                expected: Some(loaded.version),
                label: loaded.label,
            }),
            replace,
        )
    }
    fn session(&self, id: SessionId) -> Result<&Session, DocumentError> {
        self.sessions.get(&id).ok_or(DocumentError::UnknownSession)
    }
    pub fn info(&self, id: SessionId) -> Result<DocumentInfo, DocumentError> {
        let session = self.session(id)?;
        Ok(DocumentInfo {
            id,
            epoch: session.epoch,
            snapshot: session.snapshot.clone(),
            saved_revision: session.saved_revision,
            saved_durable: session.saved_durable,
            file: session.binding.as_ref().map(|target| target.file),
            label: session
                .binding
                .as_ref()
                .map(|target| target.label.clone())
                .or_else(|| session.recovered_label.clone()),
            dirty: session
                .saved_revision
                .map(|saved| saved != session.snapshot.revision())
                .unwrap_or(session.recovered || !session.snapshot.text().is_empty()),
            saving: session.pending_save.is_some(),
            format: session.format,
        })
    }
    pub fn apply(&mut self, id: SessionId, batch: ApplyBatch) -> Result<ApplyAck, DocumentError> {
        let session = self
            .sessions
            .get_mut(&id)
            .ok_or(DocumentError::UnknownSession)?;
        if session.transitioning {
            return Err(DocumentError::Busy);
        }
        if batch.epoch != session.epoch {
            return Err(DocumentError::OldEpoch);
        }
        if let Some((last, ack)) = &session.last_batch {
            if batch.sequence == last.sequence {
                return if &batch == last {
                    Ok(ack.clone())
                } else {
                    Err(DocumentError::DuplicateMismatch)
                };
            }
        }
        let expected = session
            .last_batch
            .as_ref()
            .map(|(last, _)| last.sequence)
            .unwrap_or(0)
            .checked_add(1)
            .ok_or(DocumentError::ResourceLimit)?;
        if batch.sequence != expected {
            return Err(DocumentError::SequenceGap);
        }
        if batch.base_revision != session.snapshot.revision().value() {
            return Err(DocumentError::StaleRevision);
        }
        let snapshot = session
            .snapshot
            .apply(&batch.changes)
            .map_err(DocumentError::Model)?;
        let ack = ApplyAck {
            sequence: batch.sequence,
            revision: snapshot.revision(),
        };
        session.snapshot = snapshot;
        session.last_batch = Some((batch, ack.clone()));
        Ok(ack)
    }
    pub fn prepare_save(
        &mut self,
        id: SessionId,
        epoch: EditorEpoch,
        revision: u64,
        target: Option<SaveTarget>,
    ) -> Result<SaveTicket, DocumentError> {
        let session = self.session(id)?;
        if session.transitioning {
            return Err(DocumentError::Busy);
        }
        if epoch != session.epoch {
            return Err(DocumentError::OldEpoch);
        }
        let target = target
            .or_else(|| session.binding.clone())
            .ok_or(DocumentError::NotSaved)?;
        if let Some((ticket, _)) = &session.pending_save {
            return if ticket.request.snapshot.revision().value() == revision
                && ticket.request.target == target.file
                && ticket.request.expected == target.expected
                && ticket.label == target.label
            {
                Ok(ticket.clone())
            } else {
                Err(DocumentError::Busy)
            };
        }
        if session.snapshot.revision().value() != revision {
            return Err(DocumentError::StaleRevision);
        }
        if self.sessions.iter().any(|(other, session)| {
            *other != id
                && (session.binding.as_ref().map(|t| t.file) == Some(target.file)
                    || session.pending_save.as_ref().map(|(t, _)| t.request.target)
                        == Some(target.file))
        }) {
            return Err(DocumentError::Busy);
        }
        let session = self
            .sessions
            .get_mut(&id)
            .ok_or(DocumentError::UnknownSession)?;
        self.next_ticket = self
            .next_ticket
            .checked_add(1)
            .ok_or(DocumentError::ResourceLimit)?;
        let ticket = SaveTicket {
            id: self.next_ticket,
            session: id,
            label: target.label,
            request: StorageCommit {
                target: target.file,
                expected: target.expected,
                snapshot: session.snapshot.clone(),
                format: session.format,
            },
        };
        session.pending_save = Some((ticket.clone(), false));
        Ok(ticket)
    }
    pub fn claim_save(
        &mut self,
        id: SessionId,
        epoch: EditorEpoch,
        ticket_id: u64,
    ) -> Result<Result<SaveTicket, SaveReceipt>, DocumentError> {
        let session = self
            .sessions
            .get_mut(&id)
            .ok_or(DocumentError::UnknownSession)?;
        if session.transitioning {
            return Err(DocumentError::Busy);
        }
        if session.epoch != epoch {
            return Err(DocumentError::OldEpoch);
        }
        if let Some(receipt) = &session.last_receipt {
            if receipt.ticket == ticket_id {
                return Ok(Err(receipt.clone()));
            }
        }
        let (ticket, started) = session
            .pending_save
            .as_mut()
            .ok_or(DocumentError::InvalidTicket)?;
        if ticket.id != ticket_id {
            return Err(DocumentError::InvalidTicket);
        }
        if *started {
            return Err(DocumentError::Busy);
        }
        *started = true;
        Ok(Ok(ticket.clone()))
    }
    pub fn complete_save(
        &mut self,
        ticket: &SaveTicket,
        result: Result<(DiskVersion, bool), StorageError>,
    ) -> Result<SaveReceipt, DocumentError> {
        let session = self
            .sessions
            .get_mut(&ticket.session)
            .ok_or(DocumentError::UnknownSession)?;
        if session.pending_save.as_ref().map(|(pending, _)| pending.id) != Some(ticket.id) {
            return Err(DocumentError::InvalidTicket);
        }
        session.pending_save = None;
        let (version, durable) = result.map_err(DocumentError::Storage)?;
        let receipt = SaveReceipt {
            ticket: ticket.id,
            revision: ticket.request.snapshot.revision(),
            durable,
        };
        session.saved_revision = Some(receipt.revision);
        session.saved_durable = durable;
        session.binding = Some(SaveTarget {
            file: ticket.request.target,
            expected: Some(version),
            label: ticket.label.clone(),
        });
        session.last_receipt = Some(receipt.clone());
        Ok(receipt)
    }
    pub fn abort_save(
        &mut self,
        id: SessionId,
        epoch: EditorEpoch,
        ticket: u64,
    ) -> Result<FileRef, DocumentError> {
        let session = self
            .sessions
            .get_mut(&id)
            .ok_or(DocumentError::UnknownSession)?;
        if session.transitioning {
            return Err(DocumentError::Busy);
        }
        if session.epoch != epoch {
            return Err(DocumentError::OldEpoch);
        }
        match &session.pending_save {
            Some((pending, false)) if pending.id == ticket => {
                let file = pending.request.target;
                session.pending_save = None;
                Ok(file)
            }
            Some((_, true)) => Err(DocumentError::Busy),
            _ => Err(DocumentError::InvalidTicket),
        }
    }
    pub fn close(
        &mut self,
        id: SessionId,
        epoch: EditorEpoch,
        revision: u64,
        discard: bool,
    ) -> Result<(), DocumentError> {
        self.validate_close(&CloseIntent {
            session: id,
            epoch,
            revision,
            discard,
        })?;
        self.sessions.remove(&id);
        Ok(())
    }
    fn validate_close(&self, intent: &CloseIntent) -> Result<(), DocumentError> {
        let session = self.session(intent.session)?;
        if session.epoch != intent.epoch {
            return Err(DocumentError::OldEpoch);
        }
        if session.snapshot.revision().value() != intent.revision {
            return Err(DocumentError::StaleRevision);
        }
        if session.pending_save.is_some() {
            return Err(DocumentError::Busy);
        }
        if self.info(intent.session)?.dirty && !intent.discard {
            return Err(DocumentError::NotSaved);
        }
        Ok(())
    }
    /// Reserve a validated close while recovery retirement runs outside the
    /// document mutex. No new edit/save can enter this session until completion.
    pub fn begin_close(&mut self, intent: &CloseIntent) -> Result<(), DocumentError> {
        self.validate_close(intent)?;
        let session = self.sessions.get_mut(&intent.session).unwrap();
        if session.transitioning {
            return Err(DocumentError::Busy);
        }
        session.transitioning = true;
        Ok(())
    }
    pub fn cancel_close(&mut self, id: SessionId) {
        if let Some(session) = self.sessions.get_mut(&id) {
            session.transitioning = false;
        }
    }
    pub fn restore(
        &mut self,
        recovered: crate::recovery::RecoveredText,
        replace: Option<CloseIntent>,
    ) -> Result<DocumentInfo, DocumentError> {
        let info = self.create(recovered.text, recovered.format, None, replace)?;
        let session = self.sessions.get_mut(&info.id).unwrap();
        session.recovered_label = recovered.label;
        session.recovered = true;
        self.info(info.id)
    }
    pub fn reattach(&mut self) -> Result<(DocumentInfo, Option<FileRef>), DocumentError> {
        if self.sessions.len() != 1 {
            return Err(DocumentError::UnknownSession);
        }
        let id = *self.sessions.keys().next().unwrap();
        let session = self.sessions.get_mut(&id).unwrap();
        if session.transitioning
            || session
                .pending_save
                .as_ref()
                .is_some_and(|(_, started)| *started)
        {
            return Err(DocumentError::Busy);
        }
        session.epoch = EditorEpoch(
            session
                .epoch
                .0
                .checked_add(1)
                .ok_or(DocumentError::ResourceLimit)?,
        );
        let abandoned = session
            .pending_save
            .take()
            .map(|(ticket, _)| ticket.request.target);
        session.last_batch = None;
        session.last_receipt = None;
        Ok((self.info(id)?, abandoned))
    }
    pub fn references(&self, file: FileRef) -> bool {
        self.sessions.values().any(|session| {
            session.binding.as_ref().map(|t| t.file) == Some(file)
                || session.pending_save.as_ref().map(|(t, _)| t.request.target) == Some(file)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn batch(epoch: EditorEpoch, sequence: u64, revision: u64, insert: &str) -> ApplyBatch {
        ApplyBatch {
            epoch,
            sequence,
            base_revision: revision,
            changes: vec![TextChange {
                from: 0,
                to: 0,
                insert: insert.into(),
            }],
        }
    }
    #[test]
    fn duplicate_ack_and_failed_updates_do_not_mutate_documents() {
        let mut docs = Documents::default();
        let doc = docs.new_document(None).unwrap();
        let first = batch(doc.epoch, 1, 0, "中");
        assert_eq!(
            docs.apply(doc.id, first.clone()).unwrap().revision.value(),
            1
        );
        assert_eq!(docs.apply(doc.id, first).unwrap().revision.value(), 1);
        assert_eq!(
            docs.apply(doc.id, batch(doc.epoch, 1, 0, "不同"))
                .unwrap_err(),
            DocumentError::DuplicateMismatch
        );
        assert_eq!(
            docs.apply(doc.id, batch(doc.epoch, 3, 1, "x")).unwrap_err(),
            DocumentError::SequenceGap
        );
        assert_eq!(docs.info(doc.id).unwrap().snapshot.text(), "中");
    }
    #[test]
    fn saving_fixed_revision_allows_later_input_and_never_clears_its_dirty_state() {
        let mut docs = Documents::default();
        let doc = docs.new_document(None).unwrap();
        docs.apply(doc.id, batch(doc.epoch, 1, 0, "R")).unwrap();
        let ticket = docs
            .prepare_save(
                doc.id,
                doc.epoch,
                1,
                Some(SaveTarget {
                    file: FileRef(1),
                    expected: None,
                    label: "test.md".into(),
                }),
            )
            .unwrap();
        assert!(docs
            .claim_save(doc.id, doc.epoch, ticket.id)
            .unwrap()
            .is_ok());
        docs.apply(doc.id, batch(doc.epoch, 2, 1, "R+1 ")).unwrap();
        let receipt = docs
            .complete_save(&ticket, Ok((DiskVersion("written".into()), true)))
            .unwrap();
        assert_eq!(receipt.revision.value(), 1);
        let status = docs.info(doc.id).unwrap();
        assert_eq!(status.snapshot.revision().value(), 2);
        assert!(status.dirty);
        assert_eq!(ticket.request.snapshot.text(), "R");
        assert!(docs
            .claim_save(doc.id, doc.epoch, ticket.id)
            .unwrap()
            .is_err());
    }
    #[test]
    fn failed_save_preserves_text_and_close_requires_explicit_discard() {
        let mut docs = Documents::default();
        let doc = docs.new_document(None).unwrap();
        docs.apply(doc.id, batch(doc.epoch, 1, 0, "未保存"))
            .unwrap();
        let ticket = docs
            .prepare_save(
                doc.id,
                doc.epoch,
                1,
                Some(SaveTarget {
                    file: FileRef(1),
                    expected: None,
                    label: "test.md".into(),
                }),
            )
            .unwrap();
        assert!(docs
            .complete_save(&ticket, Err(StorageError::Denied))
            .is_err());
        assert_eq!(docs.info(doc.id).unwrap().snapshot.text(), "未保存");
        assert!(docs.info(doc.id).unwrap().dirty);
        assert_eq!(
            docs.close(doc.id, doc.epoch, 1, false),
            Err(DocumentError::NotSaved)
        );
        docs.close(doc.id, doc.epoch, 1, true).unwrap();
    }
    #[test]
    fn stale_replacement_and_second_writer_do_not_remove_old_sessions() {
        let mut docs = Documents::default();
        let old = docs.new_document(None).unwrap();
        docs.apply(old.id, batch(old.epoch, 1, 0, "old")).unwrap();
        assert_eq!(
            docs.new_document(Some(CloseIntent {
                session: old.id,
                epoch: old.epoch,
                revision: 0,
                discard: true
            }))
            .unwrap_err(),
            DocumentError::StaleRevision
        );
        let target = SaveTarget {
            file: FileRef(9),
            expected: None,
            label: "same.md".into(),
        };
        docs.prepare_save(old.id, old.epoch, 1, Some(target.clone()))
            .unwrap();
        let other = docs.new_document(None).unwrap();
        assert_eq!(
            docs.prepare_save(other.id, other.epoch, 0, Some(target))
                .unwrap_err(),
            DocumentError::Busy
        );
        assert_eq!(docs.info(old.id).unwrap().snapshot.text(), "old");
    }
}
