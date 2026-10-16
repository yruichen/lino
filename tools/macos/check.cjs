const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
if (process.platform !== 'darwin') throw new Error('Native lifecycle checks require the Apple toolchain.');
const root = path.resolve(__dirname, '../..');
const output = path.join(root, '.local/validation/macos');
fs.mkdirSync(output, { recursive: true });
const checks = [
  ['application-installer', ['apps/macos/Sources/Platform/Installation/ApplicationInstaller.swift', 'tests/macos/application-installer.swift']],
  ['close-group', ['apps/macos/Sources/Application/Documents/CloseGroup.swift', 'tests/macos/close-group.swift']],
  ['document-actions', ['apps/macos/Sources/Application/Documents/CloseGroup.swift', 'apps/macos/Sources/Application/Documents/DocumentActions.swift', 'tests/macos/document-actions.swift']],
  ['release-feed', ['apps/macos/Sources/Platform/Updates/ReleaseFeedClient.swift', 'tests/macos/release-feed.swift']],
  ['image-data', ['apps/macos/Sources/Platform/Images/ImageData.swift', 'tests/macos/image-data.swift']],
  ['search-toolbar', ['apps/macos/Sources/Windows/Documents/SearchToolbarView.swift', 'tests/macos/search-toolbar.swift']],
];
const only = process.argv.find(value => value.startsWith('--only='))?.slice(7).split(',');
// This service-backed fixture reuses the bindings/library from app:build;
// default native checks remain independent of an application build.
const serviceChecks = [['navigation-sidebar', [
  '.local/generated/swift/lino_ffi.swift', 'target/release/liblino_ffi.a',
  'apps/macos/Sources/EditorHost/Backend/DocumentBackend.swift',
  'apps/macos/Sources/Application/Localization/LanguagePreferences.swift',
  ...['NavigationCoordinator', 'NavigationContentSearch', 'SidebarPresentation'].map(name => `apps/macos/Sources/Application/Navigation/${name}.swift`),
  ...['NavigationOutlineView', 'SidebarSearchController', 'SidebarCustomizationController'].map(name => `apps/macos/Sources/Windows/Navigation/${name}.swift`),
  ...['WorkspaceController', 'WorkspaceRowView'].map(name => `apps/macos/Sources/Windows/Documents/${name}.swift`),
  'apps/macos/Sources/Windows/Settings/SettingsForm.swift', 'tests/macos/navigation-sidebar.swift',
], ['-I', '.local/generated/swift', '-Xcc', '-fmodule-map-file=.local/generated/swift/lino_ffiFFI.modulemap']]];
const selectedChecks = only ? [...checks, ...serviceChecks] : checks;
if (only?.some(name => !selectedChecks.some(check => check[0] === name))) throw new Error('Unknown native check.');
for (const [name, sources, flags = []] of selectedChecks) {
  if (only && !only.includes(name)) continue;
  const executable = path.join(output, name);
  for (const [command, args] of [
    ['xcrun', ['swiftc', '-swift-version', '6', '-warnings-as-errors', ...flags, ...sources, '-o', executable]],
    [executable, []],
    ...(name === 'navigation-sidebar' ? [
      [executable, ['--visible-layout']],
      [executable, ['--closed-layout']],
    ] : []),
  ]) {
    const result = spawnSync(command, args, { cwd: root, stdio: 'inherit' });
    if (result.error) throw result.error;
    if (result.status !== 0) process.exit(result.status ?? 1);
  }
}
