const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { build } = require('../../tools/website/build.cjs');
test('website builds both languages with real release downloads, valid local links and the unchanged public update feed', () => {
  const output = fs.mkdtempSync(path.join(os.tmpdir(), 'lino-website-'));
  try {
    fs.mkdirSync(path.join(output, 'updates'));
    const tag = 'v0.0.10', name = `Lino-${tag}-macos-arm64.zip`;
    const feed = JSON.stringify([{ tag_name: tag, draft: false, prerelease: true, assets: [{ name, browser_download_url: `https://github.com/yruichen/lino/releases/download/${tag}/${name}`, digest: 'sha256:' + 'a'.repeat(64) }] }]);
    fs.writeFileSync(path.join(output, 'updates/releases.json'), feed); build(output);
    for (const language of ['', 'en/']) {
      const page = fs.readFileSync(path.join(output, language, 'index.html'), 'utf8');
      assert(!page.includes('{{')); assert(page.includes(`releases/download/${tag}/${name}`));
      assert(page.includes('v0.0.10')); assert(page.includes('Beta'));
      for (const [, href] of page.matchAll(/(?:href|src)="([^"]+)"/g)) {
        if (href.startsWith('https:')) continue;
        if (href.startsWith('#')) { assert(page.includes(`id="${href.slice(1)}"`)); continue; }
        const local = path.resolve(output, language, href);
        assert(fs.existsSync(href.endsWith('/') ? path.join(local, 'index.html') : local), href);
      }
    }
    assert.equal(fs.readFileSync(path.join(output, 'updates/releases.json'), 'utf8'), feed);
    const stable = JSON.parse(feed); stable[0].prerelease = false;
    const dmg = { ...stable[0].assets[0] };
    dmg.name = dmg.name.replace('.zip', '.dmg'); dmg.browser_download_url = dmg.browser_download_url.replace('.zip', '.dmg');
    stable[0].assets.push(dmg); fs.writeFileSync(path.join(output, 'updates/releases.json'), JSON.stringify(stable)); build(output);
    const english = fs.readFileSync(path.join(output, 'en/index.html'), 'utf8');
    assert(english.includes('Stable')); assert(!english.includes('Lino is in Beta')); assert(english.includes(dmg.browser_download_url));
    fs.writeFileSync(path.join(output, 'updates/releases.json'), '[]');
    assert.throws(() => build(output));
  } finally { fs.rmSync(output, { recursive: true, force: true }); }
});
