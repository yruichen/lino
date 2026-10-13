import assert from 'node:assert/strict';
import { test } from 'node:test';
import { ClipboardClient } from '../../packages/protocol/src/client/clipboard.ts';
import type { EditorHostEvent } from '../../packages/protocol/src/client/editor-host.ts';

test('clipboard completion requires its matching real host reply and never copies a different request', async () => {
  const sent: EditorHostEvent[] = [], client = new ClipboardClient(event => sent.push(event));
  try {
    const first = client.write('中👩🏽‍💻\ncode');
    const request = sent[0]; assert.equal(request.kind, 'clipboard-write');
    if (request.kind !== 'clipboard-write') throw new Error('Unexpected event');
    assert.equal(request.text, '中👩🏽‍💻\ncode');
    await assert.rejects(client.write('second'), /pending/);
    client.receive('old-request', null);
    await assert.rejects(client.write('second'), /pending/);
    client.receive(request.requestId, null); await first;
    const next = client.write('second');
    const second = sent[1]; if (second.kind !== 'clipboard-write') throw new Error('Unexpected event');
    assert.notEqual(second.requestId, request.requestId);
    client.receive(second.requestId, 'fixture OS write failure');
    await assert.rejects(next, /fixture OS write failure/);
  } finally { client.destroy(); }
});
test('clipboard failures release the request and close/limits never silently claim success', async () => {
  const client = new ClipboardClient(() => { throw new Error('fixture transport failure'); });
  await assert.rejects(client.write('text'), /transport failure/);
  await assert.rejects(client.write('x'.repeat(4 * 1024 * 1024 + 1)), /limit/);
  client.destroy(); await assert.rejects(client.write('text'), /closed/);
  const pending = new ClipboardClient(() => {}), result = pending.write('text');
  pending.destroy(); await assert.rejects(result, /closed/);
});
