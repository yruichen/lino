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
export class TransportError extends Error {}
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
      throw new TransportError('编辑资源与宿主能力不一致。');
    }
  }
  request(operation: Request): Promise<Response> {
    if (this.disposed) return Promise.reject(new TransportError('编辑连接已关闭。'));
    if (this.pending.size >= 32) return Promise.reject(new TransportError('编辑请求已达上限。'));
    const request_id = (++this.next).toString();
    const envelope: RequestEnvelope = { protocol_version: PROTOCOL_VERSION, request_id, operation };
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(request_id);
        reject(new TransportError('请求超时；本地内容已保留，保存结果尚未确认。'));
      }, this.timeout);
      this.pending.set(request_id, { resolve, reject, timer });
      try { this.send(JSON.stringify(envelope)); }
      catch (error) { this.fail(request_id, String(error)); }
    });
  }
  receive(json: string): void {
    let envelope: ResponseEnvelope;
    try { envelope = JSON.parse(json); } catch { this.destroy('宿主返回了无效消息。'); return; }
    if (!envelope || typeof envelope.request_id !== 'string') { this.destroy('宿主消息缺少请求标识。'); return; }
    const pending = this.pending.get(envelope.request_id);
    if (!pending) return; // Timed-out/disposed request; never attach it to another session.
    this.pending.delete(envelope.request_id); clearTimeout(pending.timer);
    if (envelope.protocol_version !== PROTOCOL_VERSION || !envelope.result || typeof envelope.result.kind !== 'string') {
      pending.reject(new TransportError('宿主协议版本或消息格式不一致。'));
    } else if (envelope.result.kind === 'error') {
      pending.reject(new ProtocolError(envelope.result.error));
    } else { pending.resolve(envelope.result); }
  }
  fail(id: string, message: string): void {
    const pending = this.pending.get(id);
    if (pending) { clearTimeout(pending.timer); this.pending.delete(id); pending.reject(new TransportError(message)); }
  }
  destroy(message = '编辑连接已关闭。'): void {
    this.disposed = true;
    for (const id of this.pending.keys()) this.fail(id, message);
  }
}
