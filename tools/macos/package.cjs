const fs = require('node:fs');
const path = require('node:path');
const { spawnSync, execFileSync } = require('node:child_process');
const { createHash } = require('node:crypto');
const root = path.resolve(__dirname, '../..');
const { version } = require('../../package.json');
if (process.platform !== 'darwin') throw Error('macOS packaging requires the Apple toolchain.');
const app = path.join(root, '.local/build/Lino.app');
const output = path.join(root, '.local/distribution');
fs.mkdirSync(output, { recursive: true });
function run(command, args) {
  const result = spawnSync(command, args, { cwd: root, stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) throw Error(`${command} failed (${result.status}).`);
}
run('codesign', ['--verify', '--deep', '--strict', app]);
const builtVersion = execFileSync('plutil', ['-extract', 'CFBundleShortVersionString', 'raw', '-o', '-', path.join(app, 'Contents/Info.plist')], { encoding: 'utf8' }).trim();
if (builtVersion !== version) throw Error(`Built app version ${builtVersion} does not match package version ${version}. Rebuild first.`);
const stem = `Lino-v${version}-macos-${process.arch}`;
const stage = fs.mkdtempSync(path.join(output, '.staging-'));
try {
  const volume = path.join(stage, 'volume'); fs.mkdirSync(volume);
  fs.cpSync(app, path.join(volume, 'Lino.app'), { recursive: true });
  fs.symlinkSync('/Applications', path.join(volume, 'Applications'));
  fs.writeFileSync(path.join(volume, 'Read Me - 请先阅读.txt'), 'Lino\n\nDrag Lino.app to Applications, eject this disk image, then open Lino from Applications.\nThe Beta is ad-hoc signed and not notarized. If macOS blocks opening, approve it in System Settings → Privacy & Security → Open Anyway.\nNever disable Gatekeeper or remove quarantine globally.\n\n将 Lino.app 拖入 Applications（应用程序），推出磁盘映像，再从应用程序中打开 Lino。\n当前 Beta 为临时签名，尚未经过 Apple 公证。如系统阻止打开，请前往「系统设置 → 隐私与安全性 → 仍要打开」批准。\n首次使用指引可设置 Markdown 默认打开方式，无需账号或完全磁盘访问权限。\n');
  const zip = path.join(stage, stem + '.zip'), dmg = path.join(stage, stem + '.dmg');
  run('ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', path.join(volume, 'Lino.app'), zip]);
  run('hdiutil', ['create', '-volname', 'Lino', '-srcfolder', volume, '-format', 'UDZO', dmg]);
  const files = [zip, dmg];
  fs.writeFileSync(path.join(stage, 'SHA256SUMS.txt'), files.map(file => `${createHash('sha256').update(fs.readFileSync(file)).digest('hex')}  ${path.basename(file)}\n`).join(''));
  for (const file of [...files, path.join(stage, 'SHA256SUMS.txt')]) fs.renameSync(file, path.join(output, path.basename(file)));
  // Only remove older artifacts produced by this packaging script after success.
  for (const name of fs.readdirSync(output)) if (/^Lino-v[\w.+-]+-macos-(arm64|x64)\.(zip|dmg)$/.test(name) && !files.some(file => path.basename(file) === name)) fs.rmSync(path.join(output, name));
  console.log(`Packaged ${stem} in ${output}`);
} finally { fs.rmSync(stage, { recursive: true, force: true }); }
