import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { readFileSync } from 'node:fs';
import { DocumentClient, ProtocolError, TransportError } from '../../packages/protocol/src/client/documents.ts';
import { formatError } from '../../packages/editor/src/localization/errors.ts';
import { setLocale } from '../../packages/editor/src/localization/index.ts';

after(() => setLocale('en'));

test('known file errors translate without appending Chinese runtime diagnostics and retain the original evidence', () => {
  const detail = { code: 'changed_externally' as const, message: '文件已被外部修改。', retryable: false };
  const error = new ProtocolError(detail);
  setLocale('en');
  assert.match(formatError(error), /save to another file/);
  assert.doesNotMatch(error.message, /\p{Script=Han}/u);
  assert.equal(error.detail, detail);
  setLocale('zh-Hans');
  assert.match(error.message, /另存/);
  assert.equal(error.detail.message, '文件已被外部修改。');
});

test('a real timed-out save request shows an unconfirmed result and same-file retry in either language', async () => {
  const client = new DocumentClient(() => {}, 1);
  try {
    await client.request({ kind: 'commit_save', session_id: '1', epoch: '1', ticket_id: '1' });
    assert.fail('Expected timeout');
  } catch (error) {
    assert.ok(error instanceof TransportError);
    assert.equal(error.code, 'timeout');
    setLocale('en');
    assert.match(formatError(error), /unconfirmed.*same file/);
    assert.doesNotMatch(error.message, /\p{Script=Han}/u);
    setLocale('zh-Hans');
    assert.match(error.message, /尚未确认.*同一文件/);
    assert.match(error.diagnostic, /timed out/);
  } finally { client.destroy(); }
});

test('native English and Chinese resources have matching keys and format arguments', () => {
  const resources = ['en', 'zh-Hans'].map(locale => {
    const source = readFileSync(new URL(`../../apps/macos/Resources/${locale}.lproj/Localizable.strings`, import.meta.url), 'utf8');
    const entries = [...source.matchAll(/^"([^"]+)" = "(.*)";$/gm)];
    assert.equal(new Set(entries.map(entry => entry[1])).size, entries.length);
    return new Map(entries.map(entry => [entry[1], entry[2]]));
  });
  assert.deepEqual([...resources[0].keys()].sort(), [...resources[1].keys()].sort());
  for (const [key, english] of resources[0]) {
    assert.doesNotMatch(english, /\p{Script=Han}/u, key);
    assert.deepEqual(english.match(/%(?:@|ld|llu)/g), resources[1].get(key)?.match(/%(?:@|ld|llu)/g), key);
  }
  assert.equal(resources[0].get('language.chinese'), 'Simplified Chinese');
});
