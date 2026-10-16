const { test } = require('node:test');
const assert = require('node:assert/strict');
const { catalog, compare } = require('../../tools/releases/catalog.cjs');
const { updatedCask } = require('../../tools/homebrew/sync.cjs');
const sha = 'a'.repeat(64);
const release = (tag, other = {}) => ({ tag_name: tag, prerelease: false, draft: false, assets: [{ name: `Lino-${tag}-macos-arm64.zip`, browser_download_url: `https://github.com/yruichen/lino/releases/download/${tag}/Lino-${tag}-macos-arm64.zip`, digest: `sha256:${sha}` }], ...other });
test('catalog orders SemVer, keeps Beta flags, excludes drafts and incomplete or untrusted downloads', () => {
  const records = [release('v0.0.9'), release('v0.0.10', { prerelease: true }), release('v9.0.0', { draft: true }), release('v8.0.0', { assets: [] }), release('../../unsafe'), release('v7.0.0', { assets: [{ name: 'Lino-v7.0.0-macos-arm64.zip', browser_download_url: 'https://example.com/', digest: `sha256:${sha}` }] })];
  assert.deepEqual(catalog(records).map(r => r.tag_name), ['v0.0.10', 'v0.0.9']);
  assert(catalog(records)[0].prerelease); assert.equal(compare('v1.0.0-beta.10', 'v1.0.0-beta.2'), 1);
  assert.equal(compare('v1.0.0', 'v1.0.0-beta.10'), 1); assert.equal(compare('1.0.0+a', '1.0.0+b'), 0);
});
test('cask sync changes version, download and checksum together, and never downgrades or replaces same-version bytes', () => {
  const original = `cask "lino" do\n  version "0.0.9"\n  sha256 "${sha}"\n  url "https://github.com/yruichen/lino/releases/download/v0.0.9/Lino-v0.0.9-macos-arm64.zip"\n  homepage "https://github.com/yruichen/lino"\nend\n`;
  const next = updatedCask(original, [release('v0.0.10')]);
  assert(next.includes('version "0.0.10"')); assert(next.includes('download/v0.0.10/Lino-v0.0.10-macos-arm64.zip'));
  assert(next.includes(`sha256 "${sha}"`)); assert(next.includes('https://yruichen.github.io/lino/'));
  assert.equal(updatedCask(next, [release('v0.0.9')]), next);
  assert.equal(updatedCask(next, [release('v0.0.10')]), next);
  assert.throws(() => updatedCask(next.replace(sha, 'b'.repeat(64)), [release('v0.0.10')]));
  assert.throws(() => updatedCask(original, [release('v0.0.10', { assets: [] })]));
});
