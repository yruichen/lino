import type { Request } from '../generated/Request.ts';
import type { RequestEnvelope } from '../generated/RequestEnvelope.ts';
import type { Response } from '../generated/Response.ts';
import type { ResponseEnvelope } from '../generated/ResponseEnvelope.ts';
import type { WireError } from '../generated/WireError.ts';
import { CAPABILITIES, PROTOCOL_VERSION, RESOURCE_VERSION } from '../generated/version.ts';

export class ProtocolError extends Error {
  readonly detail: WireError;
  constructor(detail: WireError) { super(detail.message); this.detail = detail; }
}
export type TransportErrorCode = 'unavailable' | 'closed' | 'busy' | 'timeout' | 'invalid_response' | 'incompatible';
export class TransportError extends Error {
  readonly diagnostic: string;
  readonly code: TransportErrorCode;
  constructor(diagnostic = 'Editor connection unavailable.', code: TransportErrorCode = 'unavailable') {
    super(diagnostic); this.diagnostic = diagnostic; this.code = code;
  }
}
interface Pending { resolve(value: Response): void; reject(reason: Error): void; timer: ReturnType<typeof setTimeout> }
export class DocumentClient {
  private next = 0n;
  private readonly pending = new Map<string, Pending>();
  private disposed = false;
  private readonly send: (json: string) => void;
  private readonly timeout: number;
  constructor(send: (json: string) => void, timeout = 30000) { this.send = send; this.timeout = timeout; }
  async handshake(): Promise<void> {
    const result = await this.request({ kind: 'handshake', resource_version: RESOURCE_VERSION });
    if (result.kind !== 'handshake' || result.resource_version !== RESOURCE_VERSION || CAPABILITIES.some(c => !result.capabilities.includes(c))) {
      throw new TransportError('Editor resources do not match the application.', 'incompatible');
    }
  }
  request(operation: Request): Promise<Response> {
    if (this.disposed) return Promise.reject(new TransportError('Editor connection closed.', 'closed'));
    if (this.pending.size >= 32) return Promise.reject(new TransportError('Too many pending editor requests.', 'busy'));
    const request_id = (++this.next).toString();
    const envelope: RequestEnvelope = { protocol_version: PROTOCOL_VERSION, request_id, operation };
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(request_id);
        reject(new TransportError('The operation timed out; its result is unconfirmed.', 'timeout'));
      }, this.timeout);
      this.pending.set(request_id, { resolve, reject, timer });
      try { this.send(JSON.stringify(envelope)); }
      catch (error) { this.fail(request_id, String(error)); }
    });
  }
  receive(json: string): void {
    let envelope: ResponseEnvelope;
    try { envelope = JSON.parse(json); } catch { this.destroy('Invalid application response.', 'invalid_response'); return; }
    if (!envelope || typeof envelope.request_id !== 'string') { this.destroy('Missing response request identifier.', 'invalid_response'); return; }
    const pending = this.pending.get(envelope.request_id);
    if (!pending) return; // Timed-out/disposed request; never attach it to another session.
    this.pending.delete(envelope.request_id); clearTimeout(pending.timer);
    if (envelope.protocol_version !== PROTOCOL_VERSION || !envelope.result || typeof envelope.result.kind !== 'string') {
      pending.reject(new TransportError('Invalid application response or protocol version.', 'incompatible'));
    } else if (envelope.result.kind === 'error') {
      pending.reject(new ProtocolError(envelope.result.error));
    } else { pending.resolve(envelope.result); }
  }
  fail(id: string, message: string, code: TransportErrorCode = 'unavailable'): void {
    const pending = this.pending.get(id);
    if (pending) { clearTimeout(pending.timer); this.pending.delete(id); pending.reject(new TransportError(message, code)); }
  }
  destroy(message = 'Editor connection closed.', code: TransportErrorCode = 'closed'): void {
    this.disposed = true;
    for (const id of this.pending.keys()) this.fail(id, message, code);
  }
}
