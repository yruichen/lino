import { setLocale } from '../../packages/editor/src/localization/index.ts';
before(() => setLocale('zh-Hans'));
after(() => setLocale('en'));
import assert from 'node:assert/strict';
import { before, after, test, type TestContext } from 'node:test';
import { PersistenceDeferred, SessionPersistence } from '../../packages/editor/src/session/persistence.ts';

function deferred<T>() {
  let resolve!: (value: T) => void, reject!: (reason: Error) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
async function settle() { for (let i = 0; i < 10; i++) await Promise.resolve(); }
function harness(t: TestContext) {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const state = { revision: '0', dirty: false, hasFile: false, composing: false, saving: false, pending: false };
  const checkpoints: ReturnType<typeof deferred<{revision: string; durable: boolean}>>[] = [];
  const saves: ReturnType<typeof deferred<void>>[] = [];
  const reports: string[] = [];
  const persistence = new SessionPersistence({
    state: () => state,
    checkpoint: () => { const request = deferred<{revision: string; durable: boolean}>(); checkpoints.push(request); return request.promise; },
    save: () => { const request = deferred<void>(); saves.push(request); return request.promise; },
    publish: () => {}, report: message => reports.push(message),
  }, 100, 200);
  t.after(() => persistence.destroy());
  return { state, checkpoints, saves, reports, persistence,
    async tick(ms: number) { t.mock.timers.tick(ms); await settle(); },
    accepted(revision: string) { state.revision = revision; state.dirty = true; persistence.accepted(); },
  };
}

test('recovery writes a bounded stream while continuous edits accumulate, without marking source saved', async t => {
  const h = harness(t);
  h.accepted('1'); await h.tick(60); h.accepted('2'); await h.tick(40);
  assert.equal(h.checkpoints.length, 1, 'the first write is not postponed by every edit');
  assert.equal(h.persistence.status.recoveryState, 'saving');
  for (let revision = 3; revision <= 50; revision++) h.accepted(String(revision));
  await h.tick(1000); assert.equal(h.checkpoints.length, 1, 'only one write can be in flight');
  h.checkpoints[0].resolve({revision: '2', durable: true}); await settle();
  assert.equal(h.persistence.status.recoveryRevision, '2'); assert.equal(h.persistence.status.recoveryState, 'pending');
  await h.tick(100); assert.equal(h.checkpoints.length, 2);
  h.checkpoints[1].resolve({revision: '50', durable: true}); await settle();
  assert.equal(h.persistence.status.recoveryState, 'saved'); assert(h.state.dirty, 'a recovery copy is not a source save');
  await h.tick(1000); assert.equal(h.checkpoints.length, 2);
});

test('recovery I/O failure retains the last receipt and stops automatic retries until explicitly retried', async t => {
  const h = harness(t);
  h.accepted('1'); await h.tick(100); h.checkpoints[0].resolve({revision: '1', durable: true}); await settle();
  h.accepted('2'); await h.tick(100); h.checkpoints[1].reject(new Error('disk full')); await settle();
  assert.equal(h.persistence.status.recoveryRevision, '1'); assert.equal(h.persistence.status.recoveryState, 'error');
  h.accepted('3'); await h.tick(1000); assert.equal(h.checkpoints.length, 2); assert.equal(h.reports.length, 1);
  const retry = h.persistence.retry(); await settle(); assert.equal(h.checkpoints.length, 3);
  h.checkpoints[2].resolve({revision: '3', durable: true}); await retry;
  assert.equal(h.persistence.status.recoveryRevision, '3'); assert.equal(h.persistence.status.recoveryError, null);
});

test('an unsynchronized or regressing checkpoint cannot be reported as durable recovery', async t => {
  const h = harness(t); h.accepted('5');
  const first = h.persistence.checkpoint(); await settle();
  h.checkpoints[0].resolve({revision:'5', durable:false}); await assert.rejects(first, /持久化/);
  assert.equal(h.persistence.status.recoveryRevision, null);
  const second = h.persistence.checkpoint(); await settle();
  h.checkpoints[1].resolve({revision:'4', durable:true}); await assert.rejects(second, /版本/);
  assert.equal(h.persistence.status.recoveryState,'error');
});

test('autosave only uses bound files, defers composition, and pauses after conflicts', async t => {
  const h = harness(t); h.state.dirty = true;
  h.persistence.setAutosave(true); await h.tick(1000); assert.equal(h.saves.length,0);
  h.state.hasFile = true; h.state.composing = true; h.persistence.changed();
  await h.tick(1000); assert.equal(h.saves.length,0);
  h.state.composing = false; h.persistence.changed(); await h.tick(200); assert.equal(h.saves.length,1);
  h.saves[0].reject(new Error('changed externally')); await settle();
  assert.match(h.persistence.status.autosaveError!,/changed externally/);
  h.persistence.changed(); await h.tick(1000); assert.equal(h.saves.length,1);
  h.state.dirty = false; h.persistence.saved();
  assert.equal(h.persistence.status.autosaveError,null,'a successful explicit save permits future autosaves');
  h.state.dirty = true; h.persistence.changed(); await h.tick(200); assert.equal(h.saves.length,2);
  h.state.dirty = false; h.saves[1].resolve(); await settle();
});

test('replacement freezes pending work and waits for existing writes before discard can proceed', async t => {
  const h = harness(t); h.state.hasFile = true;
  h.persistence.setAutosave(true); h.accepted('1'); await h.tick(200);
  assert.equal(h.checkpoints.length,1); assert.equal(h.saves.length,1);
  let suspended = false;
  const freezing = h.persistence.suspend().then(() => { suspended = true; });
  h.accepted('2'); await h.tick(1000); assert(!suspended);
  h.checkpoints[0].resolve({revision:'1',durable:true}); await settle(); assert(!suspended);
  h.state.dirty = false; h.saves[0].resolve(); await freezing; assert(suspended);
  await h.tick(1000); assert.equal(h.checkpoints.length,1); assert.equal(h.saves.length,1);
  h.persistence.resume(); await h.tick(100); assert.equal(h.checkpoints.length,2);
  h.checkpoints[1].resolve({revision:'2',durable:true}); await settle();
});

test('destroy cancels queued writes and ignores late receipts or failures from the old view', async t => {
  const h = harness(t); h.accepted('1'); await h.tick(100);
  h.accepted('2'); h.persistence.destroy();
  h.checkpoints[0].reject(new Error('old view')); await settle(); await h.tick(1000);
  assert.equal(h.checkpoints.length,1); assert.equal(h.reports.length,0);
  assert.equal(h.persistence.status.recoveryRevision,null);
});

test('failed background writes do not trap the replacement freeze or restart after cancel', async t => {
  const h = harness(t); h.state.hasFile = true;
  h.persistence.setAutosave(true); h.accepted('1'); await h.tick(200);
  const freeze = h.persistence.suspend();
  h.checkpoints[0].reject(new Error('disk full')); h.saves[0].reject(new Error('file changed'));
  await freeze;
  assert.equal(h.persistence.status.recoveryState,'error'); assert.match(h.persistence.status.autosaveError!,/file changed/);
  h.persistence.resume(); await h.tick(1000);
  assert.equal(h.checkpoints.length,1); assert.equal(h.saves.length,1);
});

test('a failed explicit save also stops an already scheduled automatic save', async t => {
  const h = harness(t); h.state.hasFile = true; h.state.dirty = true;
  h.persistence.setAutosave(true);
  h.persistence.saveFailed(new Error('manual save found an external conflict'));
  await h.tick(1000); assert.equal(h.saves.length,0);
  assert.match(h.persistence.status.autosaveError!,/external conflict/);
});

test('a new composition that interrupts an automatic flush defers saving until input ends', async t => {
  const h = harness(t); h.state.hasFile = true; h.state.dirty = true;
  h.persistence.setAutosave(true); await h.tick(200); assert.equal(h.saves.length,1);
  h.state.composing = true; h.saves[0].reject(new PersistenceDeferred('composition started'));
  await settle(); await h.tick(1000);
  assert.equal(h.saves.length,1); assert.equal(h.persistence.status.autosaveError,null); assert.equal(h.reports.length,0);
  h.state.composing = false; h.persistence.changed(); await h.tick(200); assert.equal(h.saves.length,2);
  h.state.dirty = false; h.saves[1].resolve(); await settle();
});
