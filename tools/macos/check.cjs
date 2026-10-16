const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
if (process.platform !== 'darwin') throw new Error('Native lifecycle checks require the Apple toolchain.');
const root = path.resolve(__dirname, '../..');
const output = path.join(root, '.local/validation/macos');
fs.mkdirSync(output, { recursive: true });
for (const [name, sources] of [
  ['close-group', ['apps/macos/Sources/Application/Documents/CloseGroup.swift', 'tests/macos/close-group.swift']],
  ['release-feed', ['apps/macos/Sources/Platform/Updates/ReleaseFeedClient.swift', 'tests/macos/release-feed.swift']],
  ['image-data', ['apps/macos/Sources/Platform/Images/ImageData.swift', 'tests/macos/image-data.swift']],
  ['search-toolbar', ['apps/macos/Sources/Windows/Documents/SearchToolbarView.swift', 'tests/macos/search-toolbar.swift']],
]) {
  const executable = path.join(output, name);
  for (const [command, args] of [
    ['xcrun', ['swiftc', '-swift-version', '6', '-warnings-as-errors', ...sources, '-o', executable]],
    [executable, []],
  ]) {
    const result = spawnSync(command, args, { cwd: root, stdio: 'inherit' });
    if (result.error) throw result.error;
    if (result.status !== 0) process.exit(result.status ?? 1);
  }
}
