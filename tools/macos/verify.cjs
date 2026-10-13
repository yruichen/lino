const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const app = path.join(root, '.local/build/Lino.app');
const executable = path.join(app, 'Contents/MacOS/Lino');
if (process.platform !== 'darwin') throw new Error('WKWebView verification requires macOS.');
if (!fs.existsSync(executable)) throw new Error('Build the application with npm run app:build first.');
const result = spawnSync(executable, ['--verify'], { cwd: root, encoding: 'utf8', timeout: 45000 });
const output = path.join(root, '.local/validation', new Date().toISOString().replace(/[:.]/g, '-'));
fs.mkdirSync(output, { recursive: true });
fs.writeFileSync(path.join(output, 'editor-wkwebview.log'), result.stdout + result.stderr);
if (result.error) throw result.error;
let report;
try { report = JSON.parse(result.stdout); }
catch { throw new Error(`Invalid native report. See ${output}/editor-wkwebview.log`); }
report.environment = { os: os.release(), architecture: process.arch, node: process.version, checkedAt: new Date().toISOString() };
fs.writeFileSync(path.join(output, 'editor-wkwebview.json'), JSON.stringify(report, null, 2) + '\n');
if (result.status !== 0 || !Array.isArray(report.passed) || !report.passed.length || !Array.isArray(report.failed) || report.failed.length) {
  console.error(report);
  process.exit(1);
}
console.log(`WKWebView: ${report.passed.length} checks passed. Report: ${output}/editor-wkwebview.json`);
console.log(report.limitation);
