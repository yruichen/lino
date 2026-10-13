import type { EditorHostEvent } from './editor-host.ts';
export const MAX_CLIPBOARD_CHARACTERS = 4 * 1024 * 1024;
export class ClipboardError extends Error {
  readonly code: 'closed' | 'busy' | 'limit' | 'transport' | 'timeout' | 'write';
  constructor(code: ClipboardError['code'], detail: string) { super(detail); this.code = code; }
}

/** Clipboard writes need a real host acknowledgement on file:// WebViews.
 * Only explicitly invoked copy actions send text; document sync is unrelated. */
export class ClipboardClient {
  private sequence = 0;
  private disposed = false;
  private pending?: { id: string; resolve: () => void; reject: (error: Error) => void; timer: ReturnType<typeof setTimeout> };
  private readonly send: (event: EditorHostEvent) => void;
  constructor(send: (event: EditorHostEvent) => void) { this.send = send; }
  write(text: string): Promise<void> {
    if (this.disposed) return Promise.reject(new ClipboardError('closed', 'Clipboard client is closed.'));
    if (this.pending) return Promise.reject(new ClipboardError('busy', 'A clipboard write is already pending.'));
    if (text.length > MAX_CLIPBOARD_CHARACTERS) return Promise.reject(new ClipboardError('limit', 'Clipboard text exceeds the 4 Mi-character message limit.'));
    const id = `clipboard-${++this.sequence}`;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => this.finish(id, new ClipboardError('timeout', 'Clipboard write was not acknowledged.')), 5000);
      this.pending = { id, resolve, reject, timer };
      try { this.send({ kind: 'clipboard-write', requestId: id, text }); }
      catch (error) { this.finish(id, new ClipboardError('transport', String(error))); }
    });
  }
  receive(id: string, error: string | null): void {
    this.finish(id, error ? new ClipboardError('write', error) : undefined);
  }
  private finish(id: string, error?: ClipboardError): void {
    const pending = this.pending;
    if (!pending || pending.id !== id) return;
    this.pending = undefined; clearTimeout(pending.timer);
    if (error) pending.reject(error); else pending.resolve();
  }
  destroy(): void {
    this.disposed = true;
    if (this.pending) this.finish(this.pending.id, new ClipboardError('closed', 'Clipboard client is closed.'));
  }
}
