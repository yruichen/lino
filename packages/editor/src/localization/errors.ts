import { ProtocolError, TransportError } from '@open-typora/protocol/documents';
import type { ErrorCode } from '@open-typora/protocol/generated/ErrorCode';
import { isLocalizedError, localizeError, localizeMessage, t } from './index.ts';

const protocolMessages = {
  unknown_session: 'error.unknownSession', old_epoch: 'error.oldEpoch', sequence_gap: 'error.sequence',
  stale_revision: 'error.stale', duplicate_mismatch: 'error.duplicate', invalid_change: 'error.invalidChange',
  busy: 'error.busy', not_saved: 'error.notSaved', invalid_ticket: 'error.invalidTicket', resource_limit: 'error.resource',
  not_found: 'error.notFound', denied: 'error.denied', changed_externally: 'error.conflict',
  unsupported_encoding: 'error.encoding', unsupported_file: 'error.fileType', too_large: 'error.resource',
  io: 'error.io', protocol_mismatch: 'error.protocol', invalid_message: 'error.message',
  unsupported_operation: 'error.unsupported', internal: 'error.internal',
} as const satisfies Record<ErrorCode, string>;

// Preserve the error class, machine code and original ProtocolError.detail.
// Its presentation remains reactive when an already-visible error changes language.
export function localizeFailure(error: unknown): unknown {
  if (!(error instanceof Error) || isLocalizedError(error)) return error;
  if (error instanceof ProtocolError && Object.hasOwn(protocolMessages, error.detail.code)) {
    const key = protocolMessages[error.detail.code], reason = error.detail.message;
    return localizeMessage(error, () => t('error.withDetails', {message: t(key), reason}));
  }
  const reason = error.message;
  return localizeError(error, error instanceof TransportError ? 'error.transport' : 'error.details', { reason });
}
export function formatError(error: unknown): string {
  const localized = localizeFailure(error);
  return localized instanceof Error ? localized.message : t('error.details', {reason: String(localized)});
}
