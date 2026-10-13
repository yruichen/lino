import { setLocale } from '../../packages/editor/src/localization/index.ts';
before(() => setLocale('zh-Hans'));
after(() => setLocale('en'));
import assert from 'node:assert/strict';
import { before, after, test } from 'node:test';
import { DocumentClient, TransportError } from '../../packages/protocol/src/client/documents.ts';
import type { RequestEnvelope } from '../../packages/protocol/src/generated/RequestEnvelope.ts';
import type { Response } from '../../packages/protocol/src/generated/Response.ts';
import type { DocumentStatus } from '../../packages/protocol/src/generated/DocumentStatus.ts';
import type { SaveTicket } from '../../packages/protocol/src/generated/SaveTicket.ts';
import type { SaveTarget } from '../../packages/protocol/src/generated/SaveTarget.ts';
import { DocumentSession } from '../../packages/editor/src/session/document.ts';
import { sourceChanges } from '../../packages/editor/src/session/changes.ts';
import { PersistenceDeferred } from '../../packages/editor/src/session/persistence.ts';

const base: DocumentStatus = { session_id: '1', epoch: '1', revision: '0', saved_revision: null, file_ref: null, label: null, dirty: false, saving: false };
function harness(timeout = 1000, status: Partial<DocumentStatus> = {}, copySaveImages?: (ticket: SaveTicket, target: SaveTarget, raw: string) => Promise<void>) {
  let text = '', composing = false;
  const queue: RequestEnvelope[] = [];
  const reports: string[] = [];
  const waiters: ((request: RequestEnvelope) => void)[] = [];
  const client = new DocumentClient(json => {
    const request = JSON.parse(json);
    const waiter = waiters.shift(); if (waiter) waiter(request); else queue.push(request);
  }, timeout);
  const session = new DocumentSession(client, { protocol_version: 1, resource_version: '0.1.0', text: '', utf8_bom: false, status: {...base, ...status} },
    { read: () => text, composing: () => composing, copySaveImages }, () => {}, message => reports.push(message));
  return {
    client, session, queued: queue, reports,
    setText(value: string) { text = value; session.changed(true); },
    compose(value: boolean) { composing = value; session.changed(false); },
    request(): Promise<RequestEnvelope> { return queue.length ? Promise.resolve(queue.shift()!) : new Promise(resolve => waiters.push(resolve)); },
    reply(request: RequestEnvelope, result: Response) { client.receive(JSON.stringify({ protocol_version: 1, request_id: request.request_id, result })); },
    dispose() { session.destroy(); client.destroy(); },
  };
}
function applied(sequence: string, revision: string, extra: Partial<DocumentStatus> = {}): Response {
  return { kind: 'applied', ack: { sequence, revision, recovery_durable: false }, status: {...base, dirty: true, revision, ...extra} };
}
test('UTF-8 range diff preserves Unicode, CRLF and exact bytes', () => {
  for (const [before, after] of [['中👩🏽‍💻\r\nB', '中👨🏽‍💻\r\nB'], ['a\r\nb', 'a\nb'], ['a\r\nb', 'a\rXb'], ['\r', '\r\n'], ['', '中🙂'], ['a🙂', 'a🙃'], ['same', 'same']]) {
    const previous = Buffer.from(before);
    const changes = sourceChanges(before, after);
    const result = changes.length ? Buffer.concat([previous.subarray(0, changes[0].from), Buffer.from(changes[0].insert), previous.subarray(changes[0].to)]).toString('utf8') : before;
    assert.equal(result, after);
    for (const change of changes) {
      for (const position of [change.from, change.to]) {
        assert.notEqual(previous[position] & 0xc0, 0x80);
        assert(!(previous[position - 1] === 13 && previous[position] === 10));
      }
    }
  }
  assert.throws(() => sourceChanges('', '\ud800'));
});
test('export capture pauses acceptance only, rejects overlapping lifecycle actions, and resumes pending input', async () => {
  const h = harness();
  try {
    await h.session.captureExport(); h.setText('typed during capture');
    await new Promise(resolve => setTimeout(resolve, 100)); assert.equal(h.queued.length, 0); assert(h.session.dirty);
    await assert.rejects(h.session.save(null)); await assert.rejects(h.session.suspend());
    h.session.endExportCapture(); const flushing = h.session.flush(), request = await h.request();
    h.reply(request, applied('1', '1')); await flushing; assert.equal(h.session.status.revision, '1');
  } finally { h.dispose(); }
});
test('Save As copies resources for R once and safely replays an uncertain commit while R+1 remains pending', async () => {
  const copies: string[] = [], h = harness(40, { file_ref: '8', label: 'old.md' }, async (_ticket, _target, raw) => { copies.push(raw); });
  try {
    h.setText('R'); const saving = assert.rejects(h.session.save({ file_ref: '9', expected_version: null, label: 'new.md' }));
    const apply = await h.request(); h.reply(apply, applied('1', '1', { file_ref: '8' }));
    const prepared = await h.request(); h.reply(prepared, { kind: 'prepared', ticket: { ticket_id: '1', revision: '1' } });
    const firstCommit = await h.request(); assert.equal(firstCommit.operation.kind, 'commit_save'); await saving;
    assert.deepEqual(copies, ['R']);
    h.setText('R+1');
    const retry = h.session.save(null), commit = await h.request();
    h.reply(commit, { kind: 'saved', receipt: { ticket_id: '1', revision: '1', durable: true }, status: { ...base, revision: '1', saved_revision: '1', file_ref: '9', label: 'new.md' } });
    await retry; assert.deepEqual(copies, ['R']); assert.equal(h.session.status.file_ref, '9'); assert(h.session.dirty);
  } finally { h.dispose(); }
});
test('failed resource copying aborts the unstarted ticket, preserving input and allowing a fresh Save As', async () => {
  const h = harness(1000, { file_ref: '8' }, async () => { throw new Error('image conflict'); });
  try {
    h.setText('R'); const saving = assert.rejects(h.session.save({ file_ref: '9', expected_version: null, label: 'new.md' }), /image conflict/);
    const apply = await h.request(); h.reply(apply, applied('1', '1'));
    const prepared = await h.request(); h.reply(prepared, { kind: 'prepared', ticket: { ticket_id: '1', revision: '1' } });
    const aborted = await h.request(); assert.equal(aborted.operation.kind, 'abort_save'); h.reply(aborted, { kind: 'aborted' }); await saving;
    assert(h.session.dirty);
    const retry = assert.rejects(h.session.save({ file_ref: '10', expected_version: null, label: 'different.md' }), /image conflict/);
    const newPrepared = await h.request(); assert.equal(newPrepared.operation.kind, 'prepare_save'); h.reply(newPrepared, { kind: 'prepared', ticket: { ticket_id: '2', revision: '1' } });
    const newAbort = await h.request(); h.reply(newAbort, { kind: 'aborted' }); await retry;
  } finally { h.dispose(); }
});
test('one in-flight batch retains later edits and bases them on its acknowledgement', async () => {
  const h = harness();
  try {
    h.setText('中'); const flushing = h.session.flush(); const first = await h.request();
    h.setText('中文🙂');
    h.reply(first, applied('1', '1')); const second = await h.request();
    assert.equal(second.operation.kind, 'apply_changes');
    if (second.operation.kind === 'apply_changes') {
      assert.equal(second.operation.base_revision, '1'); assert.equal(second.operation.sequence, '2');
      assert.deepEqual(second.operation.changes, [{from: 3, to: 3, insert: '文🙂'}]);
    }
    h.reply(second, applied('2', '2')); await flushing;
    assert(h.session.dirty); assert.equal(h.session.status.revision, '2');
  } finally { h.dispose(); }
});
test('save fixes R while R+1 input remains dirty after out-of-order save reply', async () => {
  const h = harness();
  try {
    h.setText('R'); const saving = h.session.save({file_ref:'9', expected_version:null, label:'test.md'});
    const apply = await h.request(); h.reply(apply, applied('1', '1'));
    const prepare = await h.request(); assert.equal(prepare.operation.kind, 'prepare_save');
    h.setText('R+1'); h.reply(prepare, {kind:'prepared',ticket:{ticket_id:'1',revision:'1'}});
    const commit = await h.request(); assert.equal(commit.operation.kind, 'commit_save');
    const later = await h.request(); h.reply(later, applied('2', '2'));
    h.reply(commit, {kind:'saved', receipt:{ticket_id:'1',revision:'1',durable:true}, status:{...base,revision:'1',saved_revision:'1',file_ref:'9',label:'test.md',dirty:false}});
    await saving;
    assert.equal(h.session.status.revision,'2'); assert.equal(h.session.status.saved_revision,'1'); assert(h.session.dirty);
  } finally { h.dispose(); }
});
test('uncertain edit reply replays exact sequence and payload, preserving local input', async () => {
  const h = harness(15);
  try {
    h.setText('R'); const flushing = h.session.flush(); const failed = await h.request();
    await assert.rejects(flushing, TransportError); h.setText('R+1');
    const retry = h.session.flush(); const replay = await h.request();
    assert.deepEqual(replay.operation, failed.operation);
    h.reply(replay, applied('1','1')); const later = await h.request(); h.reply(later, applied('2','2')); await retry;
  } finally { h.dispose(); }
});
test('save failure retains dirty state and allows a new save target', async () => {
  const h = harness();
  try {
    h.setText('mine'); const save = h.session.save({file_ref:'9',expected_version:null,label:'a.md'});
    const apply = await h.request(); h.reply(apply, applied('1','1'));
    const prepare = await h.request(); h.reply(prepare,{kind:'prepared',ticket:{ticket_id:'1',revision:'1'}});
    const commit = await h.request(); h.reply(commit,{kind:'error',error:{code:'changed_externally',message:'conflict',retryable:false}});
    await assert.rejects(save,/conflict/); assert(h.session.dirty);
    const retry = h.session.save({file_ref:'10',expected_version:null,label:'b.md'});
    const newPrepare = await h.request();
    assert.equal(newPrepare.operation.kind,'prepare_save');
    if(newPrepare.operation.kind === 'prepare_save') assert.equal(newPrepare.operation.target?.file_ref,'10');
    h.reply(newPrepare,{kind:'prepared',ticket:{ticket_id:'2',revision:'1'}});
    const newCommit = await h.request(); h.reply(newCommit,{kind:'saved',receipt:{ticket_id:'2',revision:'1',durable:true},status:{...base,revision:'1',saved_revision:'1',file_ref:'10',label:'b.md'}});
    await retry; assert(!h.session.dirty);
  } finally {h.dispose();}
});
test('composition blocks submission and close intent until the input is committed', async () => {
  const h = harness();
  try {
    h.compose(true); assert(h.session.dirty);
    await assert.rejects(h.session.closeIntent(true),/输入法/);
    h.compose(false); h.setText('中文'); const close = h.session.closeIntent(false);
    const apply = await h.request(); h.reply(apply,applied('1','1'));
    assert.deepEqual(await close,{session_id:'1',epoch:'1',revision:'1',discard:false});
  } finally {h.dispose();}
});

test('lost preparation reply reuses the fixed request while later input accumulates', async () => {
  const h = harness(15);
  try {
    h.setText('R'); const saving = h.session.save({file_ref:'9',expected_version:null,label:'first.md'});
    const apply = await h.request(); h.reply(apply,applied('1','1'));
    const preparation = await h.request(); await assert.rejects(saving,TransportError);
    h.setText('R+1');
    const retry = h.session.save(null); const replay = await h.request();
    assert.deepEqual(replay.operation,preparation.operation);
    h.reply(replay,{kind:'prepared',ticket:{ticket_id:'1',revision:'1'}});
    const commit = await h.request();
    h.reply(commit,{kind:'saved',receipt:{ticket_id:'1',revision:'1',durable:true},status:{...base,revision:'1',saved_revision:'1',file_ref:'9',label:'first.md'}});
    await retry; assert(h.session.dirty);
  } finally {h.dispose();}
});
test('a delayed edit reply cannot roll a Save As binding back to the old file', async () => {
  const h = harness();
  try {
    h.setText('R'); const saving = h.session.save({file_ref:'9',expected_version:null,label:'new.md'});
    const apply = await h.request(); h.reply(apply,applied('1','1'));
    const prep = await h.request(); h.reply(prep,{kind:'prepared',ticket:{ticket_id:'1',revision:'1'}});
    const commit = await h.request(); h.setText('R+1');
    const later = await h.request();
    h.reply(commit,{kind:'saved',receipt:{ticket_id:'1',revision:'1',durable:true},status:{...base,revision:'2',saved_revision:'1',file_ref:'9',label:'new.md',dirty:true}});
    await saving;
    h.reply(later,applied('2','2',{file_ref:'8',label:'old.md'}));
    await h.session.flush();
    assert.equal(h.session.status.file_ref,'9'); assert.equal(h.session.status.label,'new.md'); assert(h.session.dirty);
  } finally {h.dispose();}
});
test('explicit discard queries the authoritative revision without accepting invalid local text', async () => {
  const h = harness();
  try {
    h.setText('\ud800'); const intent = h.session.closeIntent(true); const status = await h.request();
    assert.equal(status.operation.kind,'status'); h.reply(status,{kind:'status',status:{...base,revision:'2',dirty:true}});
    assert.deepEqual(await intent,{session_id:'1',epoch:'1',revision:'2',discard:true});
    assert(h.session.dirty);
  } finally {h.dispose();}
});
test('destroy rejects pending requests and ignores late acknowledgements', async () => {
  const h = harness();
  h.setText('local'); const flushing = h.session.flush(); const apply = await h.request();
  h.dispose(); await assert.rejects(flushing,TransportError);
  h.reply(apply,applied('1','1')); assert.equal(h.session.status.revision,'0');
});

test('explicit recovery checkpoint waits for accepted text and leaves source dirty', async () => {
  const h = harness();
  try {
    h.setText('尚未保存的中文🙂');
    const checkpoint = h.session.checkpoint();
    const apply = await h.request(); assert.equal(apply.operation.kind, 'apply_changes');
    h.reply(apply, applied('1','1'));
    const write = await h.request(); assert.deepEqual(write.operation,{kind:'checkpoint',session_id:'1',epoch:'1'});
    h.reply(write,{kind:'checkpointed',revision:'1',durable:true}); await checkpoint;
    assert.equal(h.session.persistence.status.recoveryRevision,'1'); assert(h.session.dirty);
  } finally { h.dispose(); }
});

test('autosave executes the same flush/prepare/commit chain and stops on an external conflict', async t => {
  t.mock.timers.enable({apis:['setTimeout']});
  const file = {file_ref:'9',label:'test.md',saved_revision:'0'};
  const h = harness(30000,file);
  const settle = async () => { for(let i=0; i<10; i++) await Promise.resolve(); };
  try {
    h.session.persistence.setAutosave(true); h.setText('autosaved');
    t.mock.timers.tick(80); const apply = await h.request(); h.reply(apply,applied('1','1',file)); await settle();
    t.mock.timers.tick(1000); const checkpoint = await h.request();
    assert.equal(checkpoint.operation.kind,'checkpoint'); h.reply(checkpoint,{kind:'checkpointed',revision:'1',durable:true}); await settle();
    t.mock.timers.tick(920); const prepare = await h.request();
    assert.deepEqual(prepare.operation,{kind:'prepare_save',session_id:'1',epoch:'1',revision:'1',target:null});
    h.reply(prepare,{kind:'prepared',ticket:{ticket_id:'1',revision:'1'}});
    const commit = await h.request(); assert.equal(commit.operation.kind,'commit_save');
    h.reply(commit,{kind:'error',error:{code:'changed_externally',message:'external conflict',retryable:false}}); await settle();
    assert(h.session.dirty); assert.match(h.session.persistence.status.autosaveError!,/external conflict/);
    t.mock.timers.tick(10000); await settle(); assert.equal(h.queued.length,0,'automatic retries must stop after conflict');
  } finally { h.dispose(); }
});

test('a completed save refreshes recovery metadata while R+1 can be accepted independently', async t => {
  t.mock.timers.enable({apis:['setTimeout']});
  const h = harness(30000);
  const settle = async () => { for(let i=0; i<10; i++) await Promise.resolve(); };
  try {
    h.setText('R'); const saving = h.session.save({file_ref:'9',label:'saved.md',expected_version:null});
    const apply = await h.request(); h.reply(apply,applied('1','1'));
    const prepare = await h.request(); h.reply(prepare,{kind:'prepared',ticket:{ticket_id:'1',revision:'1'}});
    const commit = await h.request();
    h.reply(commit,{kind:'saved',receipt:{ticket_id:'1',revision:'1',durable:true},status:{...base,revision:'1',saved_revision:'1',file_ref:'9',label:'saved.md'}});
    await saving; assert(!h.session.dirty);
    t.mock.timers.tick(1000); const checkpoint = await h.request(); assert.equal(checkpoint.operation.kind,'checkpoint');
    h.setText('R+1'); const flushing = h.session.flush();
    const later = await h.request(); h.reply(later,applied('2','2',{saved_revision:'1',file_ref:'9',label:'saved.md'})); await flushing;
    h.reply(checkpoint,{kind:'checkpointed',revision:'1',durable:true}); await settle();
    assert.equal(h.session.persistence.status.recoveryRevision,'1'); assert(h.session.dirty);
    assert.equal(h.session.persistence.status.recoveryState,'pending');
    t.mock.timers.tick(1000); const latest = await h.request(); assert.equal(latest.operation.kind,'checkpoint');
    h.reply(latest,{kind:'checkpointed',revision:'2',durable:true}); await settle();
    assert.equal(h.session.persistence.status.recoveryRevision,'2'); assert.equal(h.session.status.saved_revision,'1');
  } finally { h.dispose(); }
});

test('replacing the editor ignores a late preparation and never starts its commit', async () => {
  const h = harness();
  try {
    h.setText('old view'); const saving = h.session.save({file_ref:'9',label:'old.md',expected_version:null});
    const apply = await h.request(); h.reply(apply,applied('1','1'));
    const prepare = await h.request(); h.session.destroy();
    h.reply(prepare,{kind:'prepared',ticket:{ticket_id:'1',revision:'1'}});
    await assert.rejects(saving,TransportError);
    assert.equal(h.queued.length,0); assert.equal(h.session.status.file_ref,null);
  } finally { h.dispose(); }
});

test('a late save result from a destroyed editor cannot replace state or warn the new view', async () => {
  const h = harness();
  try {
    h.setText('old view'); const saving = h.session.save({file_ref:'9',label:'old.md',expected_version:null});
    const apply = await h.request(); h.reply(apply,applied('1','1'));
    const prepare = await h.request(); h.reply(prepare,{kind:'prepared',ticket:{ticket_id:'1',revision:'1'}});
    const commit = await h.request(); h.session.destroy();
    h.reply(commit,{kind:'saved',receipt:{ticket_id:'1',revision:'1',durable:false},status:{...base,revision:'1',saved_revision:'1',file_ref:'9',label:'old.md'}});
    await assert.rejects(saving,TransportError);
    assert.equal(h.session.status.file_ref,null); assert.equal(h.session.status.saved_revision,null);
    assert.deepEqual(h.reports,[]);
  } finally { h.dispose(); }
});

test('composition beginning during an awaited edit defers flush without starving compositionend', async () => {
  const h = harness();
  try {
    h.setText('R'); const flushing = h.session.flush(); const apply = await h.request();
    h.compose(true); h.setText('R中文'); h.reply(apply,applied('1','1'));
    await assert.rejects(flushing,PersistenceDeferred);
    assert.equal(h.session.status.revision,'1'); assert(h.session.dirty); assert.equal(h.queued.length,0);
    h.compose(false); const committed = h.session.flush(); const next = await h.request();
    assert.equal(next.operation.kind,'apply_changes'); h.reply(next,applied('2','2')); await committed;
    assert.equal(h.session.status.revision,'2');
  } finally { h.dispose(); }
});

test('a recovery flush during a save preparation is deferred instead of spinning on a paused pump', async () => {
  const h = harness();
  try {
    h.setText('R'); const saving = h.session.save({file_ref:'9',label:'saved.md',expected_version:null});
    const apply = await h.request(); h.reply(apply,applied('1','1'));
    const prepare = await h.request(); h.setText('R+1');
    await assert.rejects(h.session.checkpoint(),PersistenceDeferred);
    h.reply(prepare,{kind:'prepared',ticket:{ticket_id:'1',revision:'1'}});
    const commit = await h.request();
    h.reply(commit,{kind:'saved',receipt:{ticket_id:'1',revision:'1',durable:true},status:{...base,revision:'1',saved_revision:'1',file_ref:'9',label:'saved.md'}});
    await saving; assert(h.session.dirty);
  } finally { h.dispose(); }
});

test('uncertain prepare or commit refuses a different Save As target and preserves the original attempt', async () => {
  for (const phase of ['prepare','commit']) {
    const h = harness(15);
    try {
      const original = {file_ref:'9',label:'original.md',expected_version:'original-version'};
      h.setText('R'); const saving = h.session.save(original);
      const apply = await h.request(); h.reply(apply,applied('1','1'));
      const prepare = await h.request(); let uncertain = prepare;
      if (phase === 'commit') {
        h.reply(prepare,{kind:'prepared',ticket:{ticket_id:'1',revision:'1'}});
        uncertain = await h.request();
      }
      await assert.rejects(saving,TransportError);
      await assert.rejects(h.session.save({file_ref:'10',label:'different.md',expected_version:null}),/尚未确认/);
      assert.equal(h.queued.length,0,'refused Save As must not send an old-target commit');
      const retry = h.session.save({...original,expected_version:'new-inspection-version'});
      const replay = await h.request(); assert.deepEqual(replay.operation,uncertain.operation);
      if (phase === 'prepare') {
        h.reply(replay,{kind:'prepared',ticket:{ticket_id:'1',revision:'1'}});
        uncertain = await h.request();
      } else { uncertain = replay; }
      h.reply(uncertain,{kind:'saved',receipt:{ticket_id:'1',revision:'1',durable:true},status:{...base,revision:'1',saved_revision:'1',file_ref:'9',label:'original.md'}});
      await retry; assert.equal(h.session.status.file_ref,'9');
    } finally { h.dispose(); }
  }
});

test('explicit persistence retry resolves the authorized old save before protecting newer input', async () => {
  const h = harness(15);
  try {
    h.setText('R'); const saving = h.session.save({file_ref:'9',label:'original.md',expected_version:'original-version'});
    const apply = await h.request(); h.reply(apply,applied('1','1'));
    const prepare = await h.request(); h.reply(prepare,{kind:'prepared',ticket:{ticket_id:'1',revision:'1'}});
    const lost = await h.request(); await assert.rejects(saving,TransportError);
    h.setText('R+1'); const retry = h.session.retryPersistence();
    const replay = await h.request(); assert.deepEqual(replay.operation,lost.operation);
    h.reply(replay,{kind:'saved',receipt:{ticket_id:'1',revision:'1',durable:true},status:{...base,revision:'1',saved_revision:'1',file_ref:'9',label:'original.md'}});
    const later = await h.request(); assert.equal(later.operation.kind,'apply_changes');
    h.reply(later,applied('2','2',{saved_revision:'1',file_ref:'9',label:'original.md'}));
    const checkpoint = await h.request(); assert.equal(checkpoint.operation.kind,'checkpoint');
    h.reply(checkpoint,{kind:'checkpointed',revision:'2',durable:true}); await retry;
    assert.equal(h.session.status.file_ref,'9'); assert.equal(h.session.status.saved_revision,'1');
    assert.equal(h.session.persistence.status.recoveryRevision,'2'); assert(h.session.dirty);
  } finally { h.dispose(); }
});
