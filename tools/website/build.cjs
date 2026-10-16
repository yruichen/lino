const fs = require('node:fs');
const path = require('node:path');
const content = require('../../website/content.cjs');
const root = path.resolve(__dirname, '../..');
function escape(value) { return String(value).replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character]); }
function build(output) {
  const releases = require('../releases/catalog.cjs').catalog(JSON.parse(fs.readFileSync(path.join(output, 'updates/releases.json'), 'utf8')));
  const latest = releases[0];
  if (!latest) throw Error('No downloadable release; website must not publish a dead download button.');
  const download = latest.assets.find(asset => asset.name.endsWith('.dmg')) ?? latest.assets.find(asset => asset.name.endsWith('.zip'));
  const beta = latest.prerelease || latest.tag_name.includes('-');
  const template = fs.readFileSync(path.join(root, 'website/index.html'), 'utf8');
  for (const [locale, strings] of Object.entries(content)) {
    const folder = locale === 'zh' ? output : path.join(output, 'en'); fs.mkdirSync(folder, { recursive: true });
    const values = { ...strings, ...(!beta ? { betaNote: strings.stableNote, downloadDescription: strings.stableDownloadDescription, faqFiveTitle: strings.stableFAQTitle, faqFiveBody: strings.stableFAQBody } : {}), prefix: locale === 'zh' ? './' : '../', canonical: `https://yruichen.github.io/lino/${locale === 'en' ? 'en/' : ''}`, languageLink: locale === 'zh' ? './en/' : '../', version: latest.tag_name, channel: beta ? 'Beta' : (locale === 'zh' ? '正式版' : 'Stable'), downloadURL: download.browser_download_url, releaseURL: `https://github.com/yruichen/lino/releases/tag/${latest.tag_name}` };
    const html = template.replace(/\{\{(\w+)\}\}/g, (_, key) => { if (!(key in values)) throw Error(`Missing website content: ${locale}.${key}`); return escape(values[key]); });
    fs.writeFileSync(path.join(folder, 'index.html'), html);
  }
  fs.mkdirSync(path.join(output, 'assets'), { recursive: true });
  for (const [source, name] of [['brand/lino.png', 'lino.png'], ['screenshots/writing.png', 'writing.png'], ['screenshots/code-and-math.png', 'code-and-math.png']]) fs.copyFileSync(path.join(root, 'assets', source), path.join(output, 'assets', name));
  for (const name of ['style.css', 'site.js']) fs.copyFileSync(path.join(root, 'website', name), path.join(output, name));
  fs.writeFileSync(path.join(output, '.nojekyll'), '');
  fs.writeFileSync(path.join(output, '404.html'), '<!doctype html><meta charset="utf-8"><title>Lino — Page not found</title><p>页面未找到 / Page not found.</p><a href="/lino/">Lino 首页 / Home</a>');
  console.log(`Built Lino website: ${latest.tag_name}, Chinese + English, ${output}`);
}
module.exports = { build };
if (require.main === module) build(path.resolve(process.argv[2] ?? path.join(root, '.local/pages')));
