const fs = require('node:fs');
const { catalog, compare, limit } = require('../releases/catalog.cjs');
function updatedCask(text, releases) {
  const latest = catalog(releases)[0];
  if (!latest) throw Error('No published arm64 release with a verified ZIP checksum.');
  const installed = /^  version "([^"]+)"$/m.exec(text)?.[1];
  if (!installed || [/^  version "[^"]+"$/gm, /^  sha256 "[^"]+"$/gm, /^  url "[^"]+"$/gm].some(pattern => [...text.matchAll(pattern)].length !== 1)) throw Error('Cannot identify the cask version, URL and checksum unambiguously.');
  const order = compare(latest.tag_name, installed);
  if (order < 0) return text; // Withdrawals never silently downgrade installed users.
  const zip = latest.assets.find(a => a.name.endsWith('.zip'));
  if (order === 0 && !text.includes(`sha256 "${zip.digest.slice(7)}"`)) throw Error('Published artifact changed without a version change; manual review required.');
  return text.replace(/^  version "[^"]+"$/m, `  version "${latest.tag_name.replace(/^v/, '')}"`)
    .replace(/^  sha256 "[^"]+"$/m, `  sha256 "${zip.digest.slice(7)}"`)
    .replace(/^  url "[^"]+"$/m, `  url "${zip.browser_download_url}"`)
    .replace(/^  homepage "[^"]+"$/m, '  homepage "https://yruichen.github.io/lino/"');
}
module.exports = { updatedCask };
if (require.main === module) (async () => {
  const target = process.argv[2];
  if (!target) throw Error('Pass the path to Casks/lino.rb.');
  const response = await fetch('https://yruichen.github.io/lino/updates/releases.json', { signal: AbortSignal.timeout(20000) });
  if (!response.ok) throw Error(`Release feed HTTP ${response.status}; existing cask preserved.`);
  let bytes = 0; const chunks = [];
  for await (const chunk of response.body) { bytes += chunk.length; if (bytes > limit) throw Error('Release feed is too large.'); chunks.push(chunk); }
  const next = updatedCask(fs.readFileSync(target, 'utf8'), JSON.parse(Buffer.concat(chunks).toString('utf8')));
  fs.writeFileSync(target, next);
})().catch(error => { console.error(error.message); process.exitCode = 1; });
