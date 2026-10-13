const { spawnSync } = require('node:child_process');
const path = require('node:path');
for (const kind of ['math', 'diagram']) {
  const result = spawnSync(process.execPath, [path.resolve(__dirname, '../../node_modules/vite/bin/vite.js'), 'build', '--config', 'vite.renderers.config.ts'], {
    cwd: path.resolve(__dirname, '../../packages/editor'), stdio: 'inherit', env: { ...process.env, OT_RENDERER: kind },
  });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
