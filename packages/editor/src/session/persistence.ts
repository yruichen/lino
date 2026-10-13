import { localizeError, t } from '../localization/index.ts';
import { formatError } from '../localization/errors.ts';
interface PersistenceSource {
  revision: string;
  dirty: boolean;
  hasFile: boolean;
  composing: boolean;
  saving: boolean;
  pending: boolean;
}
interface CheckpointReceipt { revision: string; durable: boolean }
// Input composition or another save barrier can temporarily defer a flush.
// This is not a storage failure and must not disable future automatic saves.
export class PersistenceDeferred extends Error {}
interface PersistenceActions {
  state(): PersistenceSource;
  checkpoint(): Promise<CheckpointReceipt>;
  save(): Promise<void>;
  publish(): void;
  report(message: string): void;
}
export interface PersistenceStatus {
  recoveryRevision: string | null;
  recoveryState: 'pending' | 'saving' | 'saved' | 'error';
  recoveryError: string | null;
  autosave: boolean;
  autosaveError: string | null;
}

// This coordinator owns only bounded scheduling and its I/O receipts. Document
// revisions, dirty state and save tickets remain owned by DocumentSession/Rust.
export class SessionPersistence {
  private readonly actions: PersistenceActions;
  private readonly checkpointDelay: number;
  private readonly autosaveDelay: number;
  private recoveryRevision: string | null = null;
  private recoveryError: unknown = null;
  private autosaveError: unknown = null;
  private autosave = false;
  private suspended = false;
  private disposed = false;
  private requested = 0;
  private completed = 0;
  private checkpointing: Promise<void> | undefined;
  private autosaving: Promise<void> | undefined;
  private checkpointTimer: ReturnType<typeof setTimeout> | undefined;
  private autosaveTimer: ReturnType<typeof setTimeout> | undefined;

  constructor(actions: PersistenceActions, checkpointDelay = 1000, autosaveDelay = 2000) {
    this.actions = actions; this.checkpointDelay = checkpointDelay; this.autosaveDelay = autosaveDelay;
  }
  get status(): PersistenceStatus {
    return { recoveryRevision: this.recoveryRevision, recoveryError: this.recoveryError === null ? null : formatError(this.recoveryError),
      recoveryState: this.recoveryError ? 'error' : this.checkpointing ? 'saving'
        : this.requested !== this.completed || this.actions.state().pending ? 'pending' : 'saved',
      autosave: this.autosave, autosaveError: this.autosaveError === null ? null : formatError(this.autosaveError) };
  }
  accepted(): void {
    if (this.disposed) return;
    ++this.requested; this.changed();
  }
  saved(): void {
    this.autosaveError = null;
    // Even at the same revision, Save As changed binding metadata; a clean
    // checkpoint also retires any old recovery draft.
    this.accepted();
  }
  saveFailed(error: unknown): void {
    if (!this.autosave || this.disposed || error instanceof PersistenceDeferred) return;
    this.autosaveError = error;
    if (this.autosaveTimer) { clearTimeout(this.autosaveTimer); this.autosaveTimer = undefined; }
  }
  setAutosave(enabled: boolean): void {
    this.autosave = enabled; this.autosaveError = null;
    if (!enabled && this.autosaveTimer) { clearTimeout(this.autosaveTimer); this.autosaveTimer = undefined; }
    this.changed();
  }
  changed(): void {
    if (this.disposed) return;
    this.actions.publish(); this.schedule();
  }
  private schedule(): void {
    if (this.suspended || this.disposed) return;
    // A fixed window bounds delay during continuous typing. A single pending
    // marker coalesces every edit received while the previous write is running.
    if (this.requested !== this.completed && !this.recoveryError && !this.checkpointing && !this.checkpointTimer) {
      this.checkpointTimer = setTimeout(() => {
        this.checkpointTimer = undefined;
        void this.writeCheckpoint().catch(() => {});
      }, this.checkpointDelay);
    }
    const state = this.actions.state();
    if (this.autosave && !this.autosaveError && !this.autosaving && !this.autosaveTimer
      && state.hasFile && state.dirty && !state.composing && !state.saving) {
      this.autosaveTimer = setTimeout(() => {
        this.autosaveTimer = undefined; this.startAutosave();
      }, this.autosaveDelay);
    }
  }
  private writeCheckpoint(): Promise<void> {
    if (this.checkpointing) return this.checkpointing;
    if (this.disposed) return Promise.reject(localizeError(new Error(), 'document.closed'));
    const generation = this.requested;
    const revision = this.actions.state().revision;
    const operation = (async () => {
      try {
        const receipt = await Promise.resolve().then(() => this.actions.checkpoint());
        if (this.disposed) return;
        if (BigInt(receipt.revision) < BigInt(revision)) throw localizeError(new Error(), 'recovery.oldRevision');
        if (!receipt.durable) throw localizeError(new Error(), 'recovery.notDurable');
        this.recoveryRevision = receipt.revision; this.completed = generation; this.recoveryError = null;
      } catch (error) {
        if (!this.disposed) {
          this.recoveryError = error;
          this.actions.report(t('recovery.failed', {reason: formatError(error)}));
        }
        throw error;
      } finally {
        this.checkpointing = undefined;
        if (!this.disposed) { this.actions.publish(); this.schedule(); }
      }
    })();
    this.checkpointing = operation; this.actions.publish();
    return operation;
  }
  private startAutosave(): void {
    const state = this.actions.state();
    if (this.disposed || this.suspended || !this.autosave || this.autosaveError || this.autosaving
      || !state.hasFile || !state.dirty || state.composing || state.saving) return;
    const operation = (async () => {
      try { await Promise.resolve().then(() => this.actions.save()); }
      catch (error) {
        if (!this.disposed && !(error instanceof PersistenceDeferred)) {
          this.autosaveError = error;
          this.actions.report(t('autosave.failed', {reason: formatError(error)}));
        }
      } finally {
        this.autosaving = undefined;
        if (!this.disposed) { this.actions.publish(); this.schedule(); }
      }
    })();
    this.autosaving = operation;
  }
  async checkpoint(): Promise<void> {
    if (this.checkpointTimer) { clearTimeout(this.checkpointTimer); this.checkpointTimer = undefined; }
    if (this.checkpointing) await this.checkpointing.catch(() => {});
    this.recoveryError = null;
    ++this.requested;
    await this.writeCheckpoint();
  }
  async retry(): Promise<void> {
    this.autosaveError = null;
    await this.checkpoint(); this.schedule();
  }
  async suspend(): Promise<void> {
    this.suspended = true; this.clearTimers();
    await Promise.allSettled([this.checkpointing, this.autosaving]);
  }
  resume(): void { this.suspended = false; this.schedule(); }
  destroy(): void { this.disposed = true; this.clearTimers(); }
  private clearTimers(): void {
    if (this.checkpointTimer) clearTimeout(this.checkpointTimer);
    if (this.autosaveTimer) clearTimeout(this.autosaveTimer);
    this.checkpointTimer = undefined; this.autosaveTimer = undefined;
  }
}
