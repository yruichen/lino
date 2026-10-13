const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

// Keep the PNG as the shared brand source. Generate platform representations
// inside the staged bundle, then remove intermediate PNGs before signing.
exports.writeAppIcon = function writeAppIcon(source, output) {
  const temporary = fs.mkdtempSync(path.join(path.dirname(output), '.app-icon-'));
  const iconset = path.join(temporary, 'AppIcon.iconset');
  fs.mkdirSync(iconset);
  const run = (command, args) => {
    const result = spawnSync(command, args, { encoding: 'utf8' });
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error(`${command} failed: ${result.stderr || result.stdout}`);
  };
  try {
    const rendered = new Map();
    for (const size of [16, 32, 128, 256, 512]) {
      for (const scale of [1, 2]) {
        const pixels = size * scale;
        const filename = path.join(iconset, `icon_${size}x${size}${scale === 2 ? '@2x' : ''}.png`);
        const previous = rendered.get(pixels);
        if (previous) fs.copyFileSync(previous, filename);
        else {
          run('/usr/bin/sips', ['-z', String(pixels), String(pixels), source, '--out', filename]);
          rendered.set(pixels, filename);
        }
      }
    }
    run('/usr/bin/iconutil', ['-c', 'icns', '-o', output, iconset]);
  } finally { fs.rmSync(temporary, { recursive: true, force: true }); }
};
