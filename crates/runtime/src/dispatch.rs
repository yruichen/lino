use crate::DocumentRuntime;
use open_typora_application::{
    documents::{self, DocumentError, DocumentInfo},
    ports::{DiskVersion, StorageError},
};
use open_typora_document::{
    EditorEpoch, FileRef, ModelError, SessionId, TextChange, MAX_DOCUMENT_BYTES,
};
use open_typora_protocol::{
    self as wire, ErrorCode, Request, RequestEnvelope, Response, ResponseEnvelope, WireError,
    CAPABILITIES, PROTOCOL_VERSION, RESOURCE_VERSION,
};

pub(crate) fn error(code: ErrorCode, message: &str, retryable: bool) -> WireError {
    WireError {
        code,
        message: message.into(),
        retryable,
    }
}
pub(crate) fn storage_error(value: StorageError) -> WireError {
    match value {
        StorageError::NotFound => error(ErrorCode::NotFound, "文件不存在或资源授权已失效。", false),
        StorageError::Denied => error(ErrorCode::Denied, "没有读取或写入此文件的权限。", false),
        StorageError::ChangedExternally => error(
            ErrorCode::ChangedExternally,
            "文件已被外部修改。已保留本地内容，请另存或比较后重新打开。",
            false,
        ),
        StorageError::UnsupportedEncoding => error(
            ErrorCode::UnsupportedEncoding,
            "目前仅支持 UTF-8 文档；未修改原文件。",
            false,
        ),
        StorageError::UnsupportedFile => error(
            ErrorCode::UnsupportedFile,
            "目前仅支持普通文件，不跟随文件符号链接。",
            false,
        ),
        StorageError::LimitExceeded => error(
            ErrorCode::TooLarge,
            "超过当前 64 MiB 文档或资源上限。",
            false,
        ),
        StorageError::Io(message) => {
            error(ErrorCode::Io, &format!("文件操作失败：{message}"), true)
        }
    }
}
pub(crate) fn document_error(value: DocumentError) -> WireError {
    match value {
        DocumentError::Storage(value) => storage_error(value),
        DocumentError::UnknownSession => {
            error(ErrorCode::UnknownSession, "文档会话已关闭。", false)
        }
        DocumentError::OldEpoch => error(ErrorCode::OldEpoch, "编辑写入租约已失效。", false),
        DocumentError::SequenceGap => error(
            ErrorCode::SequenceGap,
            "编辑批次顺序不一致，已保留本地内容。",
            false,
        ),
        DocumentError::StaleRevision => error(
            ErrorCode::StaleRevision,
            "文档版本已变化，不能覆盖当前状态。",
            false,
        ),
        DocumentError::DuplicateMismatch => error(
            ErrorCode::DuplicateMismatch,
            "重复批次包含不同内容。",
            false,
        ),
        DocumentError::Busy => error(
            ErrorCode::Busy,
            "文档正在保存或文件已有活跃写入会话。",
            true,
        ),
        DocumentError::NotSaved => error(ErrorCode::NotSaved, "文档尚未保存。", false),
        DocumentError::InvalidTicket => error(ErrorCode::InvalidTicket, "保存快照已失效。", false),
        DocumentError::ResourceLimit | DocumentError::Model(ModelError::LimitExceeded) => {
            error(ErrorCode::ResourceLimit, "超过当前资源上限。", false)
        }
        DocumentError::Model(_) => error(
            ErrorCode::InvalidChange,
            "编辑范围无效，不能切开 Unicode 字符或 CRLF。",
            false,
        ),
    }
}
pub(crate) fn number(value: &str) -> Result<u64, WireError> {
    if value.is_empty()
        || !value.bytes().all(|b| b.is_ascii_digit())
        || (value.len() > 1 && value.starts_with('0'))
    {
        return Err(error(
            ErrorCode::InvalidMessage,
            "协议身份必须是规范的十进制字符串。",
            false,
        ));
    }
    value
        .parse()
        .map_err(|_| error(ErrorCode::InvalidMessage, "协议数字超出范围。", false))
}
pub(crate) fn close_intent(value: wire::CloseIntent) -> Result<documents::CloseIntent, WireError> {
    Ok(documents::CloseIntent {
        session: SessionId(number(&value.session_id)?),
        epoch: EditorEpoch(number(&value.epoch)?),
        revision: number(&value.revision)?,
        discard: value.discard,
    })
}
fn status(info: DocumentInfo) -> wire::DocumentStatus {
    wire::DocumentStatus {
        session_id: info.id.0.to_string(),
        epoch: info.epoch.0.to_string(),
        revision: info.snapshot.revision().value().to_string(),
        saved_revision: info
            .saved_revision
            .map(|revision| revision.value().to_string()),
        file_ref: info.file.map(|file| file.0.to_string()),
        label: info.label,
        dirty: info.dirty,
        saving: info.saving,
    }
}
pub(crate) fn to_opened(info: DocumentInfo) -> wire::OpenedDocument {
    wire::OpenedDocument {
        protocol_version: PROTOCOL_VERSION,
        resource_version: RESOURCE_VERSION.into(),
        text: info.snapshot.text().into(),
        utf8_bom: info.format.utf8_bom,
        status: status(info),
    }
}

impl DocumentRuntime {
    pub fn dispatch(&self, input: &str) -> Result<String, serde_json::Error> {
        let envelope = if input.len() > MAX_DOCUMENT_BYTES * 6 + 65536 {
            Err(error(ErrorCode::TooLarge, "协议消息超过当前上限。", false))
        } else {
            serde_json::from_str::<RequestEnvelope>(input)
                .map_err(|_| error(ErrorCode::InvalidMessage, "无法识别协议消息。", false))
        };
        let (request_id, result) = match envelope {
            Ok(request) => {
                let result = if request.request_id.is_empty() || request.request_id.len() > 128 {
                    Err(error(ErrorCode::InvalidMessage, "请求标识无效。", false))
                } else if request.protocol_version != PROTOCOL_VERSION {
                    Err(error(
                        ErrorCode::ProtocolMismatch,
                        "宿主与编辑器协议版本不一致。",
                        false,
                    ))
                } else {
                    self.execute(request.operation)
                };
                (request.request_id, result)
            }
            Err(error) => {
                // Preserve correlation for a malformed envelope without reflecting document text.
                let id = (input.len() <= MAX_DOCUMENT_BYTES * 6 + 65536)
                    .then(|| serde_json::from_str::<serde_json::Value>(input).ok())
                    .flatten()
                    .and_then(|v| {
                        v.get("request_id")
                            .and_then(|id| id.as_str())
                            .filter(|id| id.len() <= 128)
                            .map(str::to_owned)
                    })
                    .unwrap_or_default();
                (id, Err(error))
            }
        };
        serde_json::to_string(&ResponseEnvelope {
            protocol_version: PROTOCOL_VERSION,
            request_id,
            result: result.unwrap_or_else(|error| Response::Error { error }),
        })
    }
    fn execute(&self, request: Request) -> Result<Response, WireError> {
        match request {
            Request::Handshake { resource_version } => {
                if resource_version != RESOURCE_VERSION {
                    return Err(error(
                        ErrorCode::ProtocolMismatch,
                        "编辑资源版本不一致。",
                        false,
                    ));
                }
                Ok(Response::Handshake {
                    resource_version: RESOURCE_VERSION.into(),
                    capabilities: CAPABILITIES.iter().map(|c| (*c).into()).collect(),
                })
            }
            Request::ApplyChanges {
                session_id,
                epoch,
                sequence,
                base_revision,
                changes,
            } => {
                let id = SessionId(number(&session_id)?);
                let ack = self
                    .lock()?
                    .apply(
                        id,
                        documents::ApplyBatch {
                            epoch: EditorEpoch(number(&epoch)?),
                            sequence: number(&sequence)?,
                            base_revision: number(&base_revision)?,
                            changes: changes
                                .into_iter()
                                .map(|c| TextChange {
                                    from: c.from as usize,
                                    to: c.to as usize,
                                    insert: c.insert,
                                })
                                .collect(),
                        },
                    )
                    .map_err(document_error)?;
                Ok(Response::Applied {
                    ack: wire::ApplyAck {
                        sequence: ack.sequence.to_string(),
                        revision: ack.revision.value().to_string(),
                        recovery_durable: false,
                    },
                    status: status(self.info(id)?),
                })
            }
            Request::PrepareSave {
                session_id,
                epoch,
                revision,
                target,
            } => {
                let target = target
                    .map(|value| {
                        Ok(documents::SaveTarget {
                            file: FileRef(number(&value.file_ref)?),
                            expected: value.expected_version.map(DiskVersion),
                            label: value.label,
                        })
                    })
                    .transpose()?;
                let ticket = self
                    .lock()?
                    .prepare_save(
                        SessionId(number(&session_id)?),
                        EditorEpoch(number(&epoch)?),
                        number(&revision)?,
                        target,
                    )
                    .map_err(document_error)?;
                Ok(Response::Prepared {
                    ticket: wire::SaveTicket {
                        ticket_id: ticket.id.to_string(),
                        revision: ticket.request.snapshot.revision().value().to_string(),
                    },
                })
            }
            Request::CommitSave {
                session_id,
                epoch,
                ticket_id,
            } => {
                let id = SessionId(number(&session_id)?);
                let old_file = self.info(id)?.file;
                let claimed = self
                    .lock()?
                    .claim_save(id, EditorEpoch(number(&epoch)?), number(&ticket_id)?)
                    .map_err(document_error)?;
                let receipt = match claimed {
                    Ok(ticket) => {
                        // No document lock is held during filesystem work.
                        let written = self.storage.commit(&ticket.request);
                        let result = self
                            .lock()?
                            .complete_save(&ticket, written)
                            .map_err(document_error);
                        self.release_unused(Some(ticket.request.target));
                        result?
                    }
                    Err(receipt) => receipt,
                };
                self.release_unused(old_file);
                Ok(Response::Saved {
                    receipt: wire::SaveReceipt {
                        ticket_id: receipt.ticket.to_string(),
                        revision: receipt.revision.value().to_string(),
                        durable: receipt.durable,
                    },
                    status: status(self.info(id)?),
                })
            }
            Request::AbortSave {
                session_id,
                epoch,
                ticket_id,
            } => {
                let file = self
                    .lock()?
                    .abort_save(
                        SessionId(number(&session_id)?),
                        EditorEpoch(number(&epoch)?),
                        number(&ticket_id)?,
                    )
                    .map_err(document_error)?;
                self.release_unused(Some(file));
                Ok(Response::Aborted)
            }
            Request::Checkpoint { session_id, epoch } => {
                let (revision, durable) = self.checkpoint(
                    SessionId(number(&session_id)?),
                    EditorEpoch(number(&epoch)?),
                )?;
                Ok(Response::Checkpointed { revision, durable })
            }
            Request::Status { session_id } => Ok(Response::Status {
                status: status(self.info(SessionId(number(&session_id)?))?),
            }),
            Request::Close {
                session_id,
                epoch,
                revision,
                discard,
            } => {
                self.close_document(session_id, epoch, revision, discard)?;
                Ok(Response::Closed)
            }
            Request::UnsupportedOperation => Err(error(
                ErrorCode::UnsupportedOperation,
                "当前协议不支持此操作。",
                false,
            )),
        }
    }
}
