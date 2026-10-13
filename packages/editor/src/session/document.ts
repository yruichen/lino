import { localizeError, t } from '../localization/index.ts';
import { formatError, localizeFailure } from '../localization/errors.ts';
import { DocumentClient, ProtocolError, TransportError } from '@open-typora/protocol/documents';
import type { OpenedDocument } from '@open-typora/protocol/generated/OpenedDocument';
import type { DocumentStatus } from '@open-typora/protocol/generated/DocumentStatus';
import type { Request } from '@open-typora/protocol/generated/Request';
import type { CloseIntent } from '@open-typora/protocol/generated/CloseIntent';
import type { SaveTarget } from '@open-typora/protocol/generated/SaveTarget';
import type { SaveTicket } from '@open-typora/protocol/generated/SaveTicket';
import { sourceChanges } from './changes.ts';
import { PersistenceDeferred, SessionPersistence } from './persistence.ts';
interface Source { read(): string; composing(): boolean }
interface Batch { operation: Extract<Request, {kind: 'apply_changes'}>; text: string }
export class DocumentSession {
  status: DocumentStatus;
  private accepted: string;
  private sequence = 0n;
  private batch: Batch | undefined;
  private applying: Promise<void> | undefined;
  private ticket: SaveTicket | undefined;
  private preparation: Extract<Request, {kind: 'prepare_save'}> | undefined;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private paused = false;
  private blocked = false;
  private disposed = false;
  private pending = false;
  private saving = false;
  private replacing = false;
  readonly persistence: SessionPersistence;
  private readonly client: DocumentClient;
  private readonly source: Source;
  private readonly publish: () => void;
  private readonly report: (message: string) => void;
  constructor(client: DocumentClient, document: OpenedDocument, source: Source,
    publish: () => void, report: (message: string) => void) {
    this.client = client; this.source = source; this.publish = publish; this.report = report;
    this.accepted = document.text; this.status = document.status;
    this.persistence = new SessionPersistence({
      state: () => ({ revision: this.status.revision, dirty: this.dirty, hasFile: this.status.file_ref !== null,
        composing: this.source.composing(), saving: this.isSaving, pending: this.pending || this.source.composing() }),
      checkpoint: async () => {
        const result = await this.request({ kind: 'checkpoint', session_id: this.status.session_id, epoch: this.status.epoch });
        if (result.kind !== 'checkpointed') throw localizeError(new TransportError(), 'recovery.mismatch');
        return result;
      },
      save: () => this.save(null), publish, report,
    });
    if (this.status.dirty) this.persistence.accepted();
  }
  get dirty(): boolean { return this.status.dirty || this.pending || this.source.composing(); }
  private async request(operation: Request) {
    try { return await this.client.request(operation); }
    catch (error) { throw localizeFailure(error); }
  }
  get isSaving(): boolean { return this.saving || this.status.saving; }
  changed(docChanged: boolean): void {
    if (this.disposed) return;
    this.pending ||= docChanged;
    this.persistence.changed(); this.schedule();
  }
  private schedule(): void {
    if (this.timer || this.paused || this.replacing || this.blocked || this.disposed || this.source.composing() || !this.pending) return;
    this.timer = setTimeout(() => {
      this.timer = undefined;
      void this.pump().catch(error => { if (!this.disposed) { this.blocked = true; this.report(formatError(error)); this.publish(); } });
    }, 80);
  }
  private merge(incoming: DocumentStatus, bind = false): void {
    if (incoming.session_id !== this.status.session_id || incoming.epoch !== this.status.epoch) throw localizeError(new TransportError(), 'document.wrongSession');
    // Save and edit replies can arrive in either order. Revision never regresses.
    const newest = BigInt(incoming.revision) >= BigInt(this.status.revision) ? incoming : this.status;
    const saved = [incoming.saved_revision, this.status.saved_revision].filter((v): v is string => v !== null).sort((a,b) => BigInt(a) < BigInt(b) ? 1 : -1)[0] ?? null;
    this.status = { ...newest, saved_revision: saved, file_ref: bind ? incoming.file_ref : this.status.file_ref,
      label: bind ? incoming.label : this.status.label, saving: this.saving,
      dirty: saved === null ? newest.dirty : saved !== newest.revision };
  }
  private async pump(): Promise<void> {
    if (this.applying) return this.applying;
    if (this.disposed) throw localizeError(new TransportError(), 'document.closed');
    if (this.paused || this.source.composing()) return;
    const text = this.batch?.text ?? this.source.read();
    const changes = this.batch?.operation.changes ?? sourceChanges(this.accepted, text);
    if (!changes.length) { this.pending = false; this.publish(); return; }
    const batch = this.batch ?? { text, operation: { kind: 'apply_changes' as const,
      session_id: this.status.session_id, epoch: this.status.epoch,
      sequence: (this.sequence + 1n).toString(), base_revision: this.status.revision, changes } };
    this.batch = batch;
    const applying = (async () => {
      try {
        const reply = await this.request(batch.operation);
        if (this.disposed) return;
        if (reply.kind !== 'applied' || reply.ack.sequence !== batch.operation.sequence) throw localizeError(new TransportError(), 'document.editMismatch');
        this.merge(reply.status);
        this.accepted = batch.text; this.sequence = BigInt(reply.ack.sequence); this.batch = undefined;
        this.pending = this.source.read() !== this.accepted;
        this.persistence.accepted();
      } catch (error) {
        if (this.disposed) return;
        // An uncertain transport outcome must replay the exact sequence/payload.
        if (error instanceof ProtocolError) this.batch = undefined;
        this.blocked = true; throw error;
      } finally { this.applying = undefined; this.publish(); }
    })();
    this.applying = applying;
    await applying; this.schedule();
  }
  private requireFlushAvailable(): void {
    if (this.disposed) throw localizeError(new TransportError(), 'document.closed');
    if (this.source.composing()) throw localizeError(new PersistenceDeferred(), 'editor.finishComposition');
    if (this.paused) throw localizeError(new PersistenceDeferred(), 'document.saveBarrier');
  }
  async flush(): Promise<void> {
    this.requireFlushAvailable();
    this.blocked = false;
    if (this.timer) { clearTimeout(this.timer); this.timer = undefined; }
    if (this.applying) await this.applying;
    this.requireFlushAvailable();
    while (this.batch || this.source.read() !== this.accepted) {
      await this.pump();
      // Composition can start while an acknowledgement is outstanding. Do not
      // spin on pump's no-op path and starve the compositionend event.
      this.requireFlushAvailable();
    }
    this.pending = false; this.publish();
  }
  async save(target: SaveTarget | null): Promise<void> {
    if (this.disposed) throw localizeError(new TransportError(), 'document.closed');
    if (this.saving) throw localizeError(new Error(), 'document.saving');
    if (target && this.preparation && target.file_ref !== (this.preparation.target?.file_ref ?? this.status.file_ref)) {
      throw localizeError(new Error(), 'document.unresolvedSave');
    }
    this.saving = true; this.publish();
    try {
      if (!this.ticket) {
        if (!this.preparation) {
          await this.flush();
          if (this.disposed) throw localizeError(new TransportError(), 'document.closed');
          this.preparation = { kind: 'prepare_save', session_id: this.status.session_id, epoch: this.status.epoch, revision: this.status.revision, target };
        }
        this.paused = true;
        const prepared = await this.request(this.preparation);
        if (this.disposed) throw localizeError(new TransportError(), 'document.closed');
        if (prepared.kind !== 'prepared') throw localizeError(new TransportError(), 'document.prepareMismatch');
        // Keep the original target and expected version until commit is known.
        // A later Save As must not silently replay a ticket for another file.
        this.ticket = prepared.ticket;
      }
      this.paused = false; this.schedule();
      const reply = await this.request({ kind: 'commit_save', session_id: this.status.session_id, epoch: this.status.epoch, ticket_id: this.ticket.ticket_id });
      if (this.disposed) throw localizeError(new TransportError(), 'document.closed');
      if (reply.kind !== 'saved' || reply.receipt.ticket_id !== this.ticket.ticket_id) throw localizeError(new TransportError(), 'document.saveMismatch');
      this.merge(reply.status, true); this.ticket = undefined; this.preparation = undefined;
      this.persistence.saved();
      if (!reply.receipt.durable) this.report(t('document.saveNotDurable'));
    } catch (error) {
      if (error instanceof ProtocolError && error.detail.code !== 'busy') { this.ticket = undefined; this.preparation = undefined; }
      this.persistence.saveFailed(error);
      throw error;
    } finally { this.saving = false; this.status = {...this.status, saving: false}; this.paused = false; this.schedule(); this.persistence.changed(); }
  }
  async checkpoint(): Promise<void> { await this.flush(); await this.persistence.checkpoint(); }
  async retryPersistence(): Promise<void> {
    if (this.preparation || this.ticket) await this.save(null);
    await this.flush(); await this.persistence.retry();
  }
  async suspend(): Promise<void> {
    this.replacing = true;
    if (this.timer) { clearTimeout(this.timer); this.timer = undefined; }
    await this.persistence.suspend();
    // The close intent must follow every already-started edit, including an
    // uncertain one. A failed edit can still be explicitly discarded.
    if (this.applying) await this.applying.catch(() => {});
  }
  resume(): void { this.replacing = false; this.persistence.resume(); this.schedule(); }
  async closeIntent(discard: boolean): Promise<CloseIntent> {
    if (this.source.composing()) throw localizeError(new Error(), 'editor.finishComposition');
    if (discard) {
      // Explicit discard may close an unacknowledged/invalid local batch. Query
      // the authoritative revision without rewriting its local replay baseline.
      const result = await this.request({kind: 'status', session_id: this.status.session_id});
      if (result.kind !== 'status') throw localizeError(new TransportError(), 'document.closeStatusMismatch');
      return {session_id: result.status.session_id, epoch: result.status.epoch, revision: result.status.revision, discard};
    }
    await this.flush();
    return { session_id: this.status.session_id, epoch: this.status.epoch, revision: this.status.revision, discard };
  }
  async closePrepared(intent: CloseIntent): Promise<void> {
    const result = await this.request({ kind: 'close', ...intent });
    if (result.kind !== 'closed') throw localizeError(new TransportError(), 'document.closeMismatch');
    this.destroy();
  }
  destroy(): void { this.disposed = true; if (this.timer) clearTimeout(this.timer); this.persistence.destroy(); }
}
