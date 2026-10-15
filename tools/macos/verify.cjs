const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const app = path.join(root, '.local/build/Lino.app');
if (process.argv.includes('--preview')) throw new Error('Preview output was removed. Verification uses .local/build/Lino.app.');
const executable = path.join(app, 'Contents/MacOS/Lino');
if (process.platform !== 'darwin') throw new Error('WKWebView verification requires macOS.');
if (!fs.existsSync(executable)) throw new Error('Build the application with npm run app:build first.');
const focused = process.argv.includes('--focused');
const mode = focused ? '--verify-navigation' : process.argv.includes('--settings-layout') ? '--verify-settings' : process.argv.includes('--settings') ? '--verify-settings' : process.argv.includes('--navigation') ? '--verify-navigation' : '--verify';
const args = process.argv.includes('--settings-layout') ? [mode, '--layout-only'] : [mode];
if (process.argv.includes('--settings-layout') && process.argv.includes('--selection-only')) args.push('--selection-only');
if (process.argv.includes('--navigation') && process.argv.includes('--presentation-only')) args.push('--presentation-only');
if (focused) args.push('--focused');
if (process.argv.includes('--headless')) args.push('--headless');
const stage = process.argv.find(value => value.startsWith('--stage=') || value.startsWith('--stages='));
const stages = stage?.split('=')[1].split(',');
if (stage) {
  if (!focused || !stages.every(value => ['upgrade', 'navigation', 'media-output', 'appearance', 'image-references', 'window-chrome'].includes(value))) throw new Error('Unknown focused verification stage.');
  args.push(stage);
}
const output = path.join(root, '.local/validation');
fs.mkdirSync(output, { recursive: true });
const result = spawnSync(executable, args, { cwd: root, encoding: 'utf8', timeout: focused ? 90000 : 45000 });
fs.writeFileSync(path.join(output, 'latest.log'), (result.stdout ?? '') + (result.stderr ?? '') + (result.error ? result.error.message + '\n' : ''));
let report;
try { report = JSON.parse(result.stdout); }
catch { report = { passed: [], failed: [result.error?.message ?? (result.signal ? `Native verification stopped with ${result.signal}.` : 'Native verification did not return a valid report.')] }; }
if (result.error && Array.isArray(report.failed) && !report.failed.includes(result.error.message)) report.failed.push(result.error.message);
if (result.status !== 0 && Array.isArray(report.failed) && !report.failed.length) report.failed.push(`Native verification exited with status ${result.status}.`);
report.scope = focused ? stages?.join(',') ?? 'navigation-media-appearance' : process.argv.includes('--settings-layout') ? (process.argv.includes('--selection-only') ? 'settings-selection' : 'settings-layout') : process.argv.includes('--settings') ? 'settings' : process.argv.includes('--navigation') ? (process.argv.includes('--presentation-only') ? 'navigation-presentation' : 'navigation') : 'full';
report.environment = { os: os.release(), architecture: process.arch, node: process.version, checkedAt: new Date().toISOString() };
fs.writeFileSync(path.join(output, 'latest.json'), JSON.stringify(report, null, 2) + '\n');
// Retire the former fixed report location after the latest report is written.
for (const extension of ['json', 'log']) fs.rmSync(path.join(root, '.local/validation', `editor-wkwebview.${extension}`), { force: true });
fs.rmSync(path.join(output, 'wkwebview'), { recursive: true, force: true });
if (result.status !== 0 || !Array.isArray(report.passed) || !report.passed.length || !Array.isArray(report.failed) || report.failed.length) {
  console.error(report);
  process.exit(1);
}
console.log(`WKWebView: ${report.passed.length} checks passed. Report: ${output}/latest.json`);
if (report.limitation) console.log(report.limitation);
