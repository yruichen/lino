const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const { version } = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
const buildRoot = path.join(root, '.local/build');
const app = path.join(buildRoot, 'OpenTypora.app');
if (process.platform !== 'darwin') throw new Error('The AppKit host must be built on macOS.');
const currentApp = fs.existsSync(app) ? fs.realpathSync(app) : null;
function requireClosedApp() {
  if (!currentApp) return;
  const relative = path.relative(buildRoot, currentApp);
  if (relative.startsWith('..') || path.isAbsolute(relative)) throw new Error('Application output must stay inside .local/build.');
  const processes = spawnSync('ps', ['-axo', 'args='], { encoding: 'utf8' });
  if (processes.error) throw processes.error;
  if (processes.status !== 0) throw new Error('Could not check whether the current application is running.');
  const executables = [app, currentApp].map(bundle => path.join(bundle, 'Contents/MacOS/OpenTypora'));
  if (processes.stdout.split('\n').some(line => executables.some(executable => line.trim() === executable || line.trim().startsWith(executable + ' ')))) {
    throw new Error('Quit Open Typora before rebuilding. The current application has been kept.');
  }
}
requireClosedApp();
fs.mkdirSync(buildRoot, { recursive: true });
const staging = fs.mkdtempSync(path.join(buildRoot, '.staging-'));
const stagedApp = path.join(staging, 'OpenTypora.app');
let preserveStaging = false;
process.on('exit', () => { if (!preserveStaging) fs.rmSync(staging, { recursive: true, force: true }); });
process.env.MACOSX_DEPLOYMENT_TARGET = '14.0';
const rustBuild = path.join(root, 'target');
process.env.CARGO_TARGET_DIR = rustBuild;
function run(command, args) {
  const result = spawnSync(command, args, { cwd: root, stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
run('npm', ['run', 'protocol:generate']);
run('cargo', ['build', '--target-dir', rustBuild, '--release', '--locked', '-p', 'open-typora-ffi']);
const generated = path.join(root, '.local/generated/swift');
run('cargo', ['run', '--locked', '-p', 'open-typora-ffi', '--features', 'bindgen', '--bin', 'generate-swift', '--', 'generate', '--library', path.join(rustBuild, 'release/libopen_typora_ffi.dylib'), '--language', 'swift', '--out-dir', generated]);
run('npm', ['run', 'typecheck', '--workspace', '@open-typora/editor']);
run('npm', ['run', 'build', '--workspace', '@open-typora/editor']);
const contents = path.join(stagedApp, 'Contents');
const resources = path.join(contents, 'Resources/Editor');
fs.mkdirSync(path.join(contents, 'MacOS'), { recursive: true });
fs.rmSync(resources, { recursive: true, force: true });
fs.mkdirSync(resources, { recursive: true });
fs.cpSync(path.join(root, 'packages/editor/dist'), resources, { recursive: true });
fs.copyFileSync(path.join(root, 'packages/editor/index.html'), path.join(resources, 'index.html'));
const nativeResources = path.join(root, 'apps/macos/Resources');
for (const entry of fs.readdirSync(nativeResources)) {
  fs.cpSync(path.join(nativeResources, entry), path.join(contents, 'Resources', entry), { recursive: true });
}
require('./licenses.cjs').writeLicenses(root, path.join(contents, 'Resources/Licenses'));
const sources = fs.readdirSync(path.join(root, 'apps/macos/Sources'), { recursive: true }).filter(file => file.endsWith('.swift')).sort().map(file => path.join(root, 'apps/macos/Sources', file));
run('xcrun', ['swiftc', '-swift-version', '6', '-warnings-as-errors', '-O', '-target', `${process.arch === 'arm64' ? 'arm64' : 'x86_64'}-apple-macosx14.0`, '-framework', 'AppKit', '-framework', 'WebKit', '-I', generated, '-Xcc', `-fmodule-map-file=${path.join(generated, 'open_typora_ffiFFI.modulemap')}`, path.join(generated, 'open_typora_ffi.swift'), path.join(rustBuild, 'release/libopen_typora_ffi.a'), ...sources, '-o', path.join(contents, 'MacOS/OpenTypora')]);
fs.writeFileSync(path.join(contents, 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OpenTypora</string>
<key>CFBundleIdentifier</key><string>dev.open-typora.editor</string>
<key>CFBundleName</key><string>Open Typora</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${version}</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>\n`);
run('codesign', ['--force', '--sign', '-', stagedApp]);
requireClosedApp();
// Publish only a complete bundle. Retain the previous one if publication fails,
// then remove it on success instead of accumulating named review builds.
const previous = path.join(staging, 'previous.app');
const replacing = fs.existsSync(app);
if (replacing) fs.renameSync(app, previous);
try { fs.renameSync(stagedApp, app); }
catch (error) {
  if (replacing) {
    // A moved relative symlink is temporarily dangling; restore the directory
    // entry without testing whether its relocated target can be resolved.
    try { fs.renameSync(previous, app); }
    catch (restoreError) {
      preserveStaging = true;
      throw new AggregateError([error, restoreError], `Publication failed; previous output retained at ${previous}`);
    }
  }
  throw error;
}
// A local alias may point at the application that was already open during
// cleanup. Once it is closed and replaced, its old bundle is no longer needed.
if (currentApp && currentApp !== app) {
  fs.rmSync(currentApp, { recursive: true });
  const parent = path.dirname(currentApp);
  if (parent !== buildRoot && fs.readdirSync(parent).length === 0) fs.rmdirSync(parent);
}
console.log(`Built ${app}`);
