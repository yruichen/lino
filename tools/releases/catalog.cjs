const fs = require('node:fs');
const path = require('node:path');
const repository = 'https://github.com/yruichen/lino';
const limit = 2 * 1024 * 1024;
function version(tag) {
  const match = /^(?:v)?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([\da-zA-Z-]+(?:\.[\da-zA-Z-]+)*))?(?:\+[\da-zA-Z-]+(?:\.[\da-zA-Z-]+)*)?$/.exec(tag);
  if (!match || match[4]?.split('.').some(part => /^0\d+$/.test(part))) return null;
  return { core: match.slice(1, 4).map(BigInt), pre: match[4]?.split('.') ?? [] };
}
function compare(left, right) {
  const a = version(left), b = version(right);
  if (!a || !b) throw Error('Invalid release version.');
  for (let i = 0; i < 3; i++) if (a.core[i] !== b.core[i]) return a.core[i] > b.core[i] ? 1 : -1;
  if (!a.pre.length || !b.pre.length) return !a.pre.length - !b.pre.length;
  for (let i = 0; i < Math.max(a.pre.length, b.pre.length); i++) {
    const x = a.pre[i], y = b.pre[i];
    if (x === y) continue;
    if (x === undefined || y === undefined) return x === undefined ? -1 : 1;
    const xn = /^\d+$/.test(x), yn = /^\d+$/.test(y);
    if (xn && yn) return BigInt(x) > BigInt(y) ? 1 : -1;
    if (xn !== yn) return xn ? -1 : 1;
    return x > y ? 1 : -1;
  }
  return 0;
}
function catalog(input) {
  if (!Array.isArray(input) || input.length > 1000) throw Error('Invalid release list or too many releases.');
  const result = input.filter(r => r && r.draft === false && typeof r.tag_name === 'string' && version(r.tag_name) && typeof r.prerelease === 'boolean').map(r => {
    const assets = (Array.isArray(r.assets) ? r.assets : []).filter(a => {
      if (!a || !['zip', 'dmg'].some(extension => a.name === `Lino-${r.tag_name}-macos-arm64.${extension}`)) return false;
      return a.browser_download_url === `${repository}/releases/download/${r.tag_name}/${a.name}` && /^sha256:[a-f0-9]{64}$/.test(a.digest);
    }).map(a => ({ name: a.name, browser_download_url: a.browser_download_url, digest: a.digest }));
    return { tag_name: r.tag_name, prerelease: r.prerelease, draft: false, assets };
  }).filter(r => r.assets.some(a => a.name.endsWith('.zip'))).sort((a, b) => compare(b.tag_name, a.tag_name));
  if (Buffer.byteLength(JSON.stringify(result)) > limit) throw Error('Release catalog exceeds the client size limit.');
  return result;
}
module.exports = { catalog, compare, version, limit, repository };
if (require.main === module) {
  const [input, output] = process.argv.slice(2);
  if (!input || !output) throw Error('Usage: node tools/releases/catalog.cjs releases.json output.json');
  fs.mkdirSync(path.dirname(output), { recursive: true });
  fs.writeFileSync(output, JSON.stringify(catalog(JSON.parse(fs.readFileSync(input, 'utf8'))), null, 2) + '\n');
}
