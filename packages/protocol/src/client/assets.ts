import type { EditorHostEvent } from './editor-host.ts';
export type AssetOperation = 'import-file' | 'paste-image' | 'reveal-image' | 'copy-image' | 'save-svg' | 'open-link' | 'copy-save-images';
export interface AssetPort {
  request(operation: AssetOperation, payload?: string): Promise<string | null>;
  imageURL(source: string, fresh?: boolean): string;
}
export class AssetLocationError extends Error {
  constructor() { super('Save or open a document file before loading relative images'); }
}
export class AssetsClient implements AssetPort {
  private next = 0;
  private context = 0;
  private fileRef: string | null = null;
  private sessionId: string | null = null;
  private readonly namespace = Array.from(crypto.getRandomValues(new Uint32Array(4)), value => value.toString(16)).join('-');
  private destroyed = false;
  private readonly pending = new Map<string, { resolve(value: string | null): void; reject(error: Error): void; timer?: ReturnType<typeof setTimeout> }>();
  private readonly send: (event: EditorHostEvent) => void;
  constructor(send: (event: EditorHostEvent) => void) { this.send = send; }
  invalidate(): void { this.context++; }
  setDocument(sessionId: string | null, fileRef: string | null): void {
    if (this.sessionId !== sessionId || this.fileRef !== fileRef) { this.sessionId = sessionId; this.fileRef = fileRef; this.invalidate(); }
  }
  imageURL(source: string, fresh = false): string {
    if (this.sessionId === null || this.fileRef === null) throw new AssetLocationError();
    if (fresh) this.invalidate();
    return `ot-image://local/image?view=${this.namespace}&context=${this.context}&session=${this.sessionId ?? ''}&file=${this.fileRef ?? ''}&source=${encodeURIComponent(source)}`;
  }
  request(operation: AssetOperation, payload = ''): Promise<string | null> {
    if (this.destroyed) return Promise.reject(new Error('Resource connection closed'));
    if (this.pending.size) return Promise.reject(new Error('A resource operation is already in progress'));
    if (new TextEncoder().encode(payload).byteLength > 4 * 1024 * 1024) return Promise.reject(new Error('Resource payload exceeds the limit'));
    const requestId = String(++this.next);
    return new Promise((resolve, reject) => {
      // Interactive file panels have user-controlled duration. Only bounded
      // noninteractive I/O has a transport deadline; teardown always rejects.
      const timer = operation === 'import-file' || operation === 'save-svg' ? undefined : setTimeout(() => this.receive(requestId, null, 'Resource operation timed out; a written resource may still exist'), 120_000);
      this.pending.set(requestId, { resolve, reject, timer });
      try { this.send({ kind: 'asset-operation', requestId, operation, payload, sessionId: this.sessionId, fileRef: this.fileRef }); }
      catch (error) { this.receive(requestId, null, String(error)); }
    });
  }
  receive(id: string, value: string | null, error: string | null): boolean {
    const pending = this.pending.get(id); if (!pending) return false;
    this.pending.delete(id); clearTimeout(pending.timer);
    if (error !== null) pending.reject(new Error(error)); else pending.resolve(value);
    return true;
  }
  destroy(): void {
    this.destroyed = true;
    for (const id of this.pending.keys()) this.receive(id, null, 'Resource connection closed');
  }
}
