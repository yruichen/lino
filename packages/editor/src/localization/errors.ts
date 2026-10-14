import { ProtocolError, TransportError } from '@lino/protocol/documents';
import { AssetError } from '@lino/protocol/assets';
import type { ErrorCode } from '@lino/protocol/generated/ErrorCode';
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
    const key = protocolMessages[error.detail.code];
    return localizeMessage(error, () => t(key));
  }
  if (error instanceof AssetError) return localizeError(error, `asset.${error.code}`);
  if (error instanceof TransportError) return localizeError(error, `transport.${error.code}`);
  const reason = error.message;
  return localizeError(error, 'error.details', { reason });
}
export function formatError(error: unknown): string {
  const localized = localizeFailure(error);
  return localized instanceof Error ? localized.message : t('error.details', {reason: String(localized)});
}
