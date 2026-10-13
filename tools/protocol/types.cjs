const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const check = process.argv.includes('--check');
const target = path.join(root, 'packages/protocol/src/generated');
fs.mkdirSync(path.join(root, '.local'), { recursive: true });
const output = check ? fs.mkdtempSync(path.join(root, '.local/protocol-check-')) : target;
const result = spawnSync('cargo', ['run', '--locked', '-p', 'lino-protocol', '--bin', 'generate-protocol', '--', output], { cwd: root, stdio: 'inherit' });
if (result.error) throw result.error;
if (result.status !== 0) process.exit(result.status ?? 1);
for (const name of fs.readdirSync(output).filter(name => name.endsWith('.ts'))) {
  const file = path.join(output, name);
  fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace(/[\t ]+$/gm, ''));
}
if (check) {
  const names = fs.readdirSync(output).sort();
  if (JSON.stringify(names) !== JSON.stringify(fs.readdirSync(target).sort()) || names.some(name => fs.readFileSync(path.join(output, name), 'utf8') !== fs.readFileSync(path.join(target, name), 'utf8'))) throw new Error('Generated protocol differs. Run npm run protocol:generate.');
  fs.rmSync(output, { recursive: true });
  console.log('Generated protocol matches the Rust DTOs.');
}
