import assert from 'node:assert/strict';
import { test } from 'node:test';
import { AssetLocationError, AssetsClient } from '../../packages/protocol/src/client/assets.ts';
import type { EditorHostEvent } from '../../packages/protocol/src/client/editor-host.ts';
test('asset client only resolves matching host acknowledgement; cancellation, failure, busy and disposal are observable', async () => {
  const sent: EditorHostEvent[] = [], client = new AssetsClient(event => sent.push(event));
  client.setDocument('1', '2');
  const first = client.request('import-file'); await assert.rejects(client.request('paste-image'));
  assert.equal(client.receive('wrong', 'fake.png', null), false); assert.equal(sent[0].kind, 'asset-operation');
  assert.equal(sent[0].kind === 'asset-operation' && sent[0].sessionId, '1'); assert.equal(sent[0].kind === 'asset-operation' && sent[0].fileRef, '2');
  client.receive('1', null, null); assert.equal(await first, null);
  const second = client.request('paste-image'), rejected = assert.rejects(second, /fixture failure/); client.receive('2', null, 'fixture failure'); await rejected;
  const third = client.request('import-file'), destroyed = assert.rejects(third, /closed/); client.destroy(); await destroyed;
  await assert.rejects(client.request('save-svg')); assert(client.imageURL('a%20b.png').includes('a%2520b.png'));
  const previous = client.imageURL('a.png'); assert.equal(client.imageURL('a.png'), previous);
  assert.notEqual(client.imageURL('a.png', true), previous);
  const other = new AssetsClient(() => {}); other.setDocument('1', '2'); assert.notEqual(other.imageURL('a.png'), previous); other.destroy();
  const bound = client.imageURL('a.png'); client.setDocument('1', '3'); assert.notEqual(client.imageURL('a.png'), bound); assert(client.imageURL('a.png').includes('file=3'));
  const limited = new AssetsClient(() => { throw new Error('oversized payload was sent'); });
  await assert.rejects(limited.request('save-svg', '中'.repeat(1_400_000)), /limit/); limited.destroy();
});
test('relative image URLs require a bound file and become available after saving without changing the source', () => {
  const client = new AssetsClient(() => { throw new Error('No resource operation should be sent'); });
  const source = '图片 assets/日出.svg';
  try {
    assert.throws(() => client.imageURL(source), AssetLocationError);
    client.setDocument('1', null); assert.throws(() => client.imageURL(source), AssetLocationError);
    client.setDocument('1', '2');
    const url = new URL(client.imageURL(source));
    assert.equal(url.searchParams.get('source'), source); assert.equal(url.searchParams.get('file'), '2');
    client.setDocument('3', null); assert.throws(() => client.imageURL(source), AssetLocationError);
  } finally { client.destroy(); }
});
