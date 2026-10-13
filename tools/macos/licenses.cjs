const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

// These upstream releases omit their repository license from the crate archive.
// Match the recorded source revision so an upgrade cannot silently reuse it.
const supplements = [
  { repository: 'https://github.com/Aleph-Alpha/ts-rs', revision: '7182ad8289596097235406b715fa04506443b4ad', file: 'ts-rs-12.0.1.LICENSE' },
  { repository: 'https://github.com/mozilla/uniffi-rs', revision: '7bc621ee9d0d15371d792612707ba5ed4111f950', file: 'uniffi-0.32.2.LICENSE' },
  { repository: 'https://github.com/madsmtm/objc2', revision: '8d214f5477365ffcbcbb7de058c86ed9a518efb7', file: 'objc2-encode-4.1.0.LICENSE' },
  { repository: 'https://github.com/madsmtm/objc2', revision: 'd7d2fa23ceaa5e6096c923b081040e5d81b3b9df', file: 'objc2-0.6.5.LICENSE' },
  { repository: 'https://github.com/madsmtm/objc2', revision: '7b1abfd750a2cacaea71d6a56ecfb83cb7de560b', file: 'objc2-foundation-0.3.2.LICENSE' },
];
const licenseName = /^(?:licen[cs]e|copying|copyright|notice)(?:[._-]|$)/i;
const objc2MitSource = 'https://github.com/madsmtm/objc2/blob/757cd841d0293341dbefd9b99d7548dec244ffde/LICENSE.txt';

function writeLicenses(root, destination) {
  const notices = [];
  const texts = new Map();
  function add(name, source, files) {
    if (files.length === 0) throw new Error(`No license text found for ${name}.`);
    const references = [];
    for (const file of [...new Set(files)].sort()) {
      const content = fs.readFileSync(file, 'utf8');
      if (!content.trim()) throw new Error(`Empty license text for ${name}: ${file}`);
      if (!texts.has(content)) texts.set(content, { number: texts.size + 1, owners: [] });
      const text = texts.get(content);
      text.owners.push(`${name}: ${path.basename(file)}`);
      references.push(text.number);
    }
    notices.push(`${name}\nSource: ${source}\nLicense texts: ${[...new Set(references)].join(', ')}`);
  }
  function licenseFiles(directory) {
    return fs.readdirSync(directory, { withFileTypes: true })
      .filter(entry => entry.isFile() && licenseName.test(entry.name))
      .map(entry => path.join(directory, entry.name));
  }

  // Walk the installed production graph, including transitive dependencies.
  const visited = new Set();
  function visitNpm(directory) {
    directory = fs.realpathSync(directory);
    if (visited.has(directory)) return;
    visited.add(directory);
    const pkg = JSON.parse(fs.readFileSync(path.join(directory, 'package.json'), 'utf8'));
    if (!pkg.name.startsWith('@lino/')) {
      add(`npm ${pkg.name}@${pkg.version}`, `https://www.npmjs.com/package/${pkg.name}/v/${pkg.version}`, licenseFiles(directory));
    }
    const dependencies = { ...pkg.dependencies, ...pkg.optionalDependencies, ...pkg.peerDependencies };
    for (const name of Object.keys(dependencies).sort()) {
      let parent = directory;
      while (!fs.existsSync(path.join(parent, 'node_modules', name, 'package.json')) && path.dirname(parent) !== parent) parent = path.dirname(parent);
      const dependency = path.join(parent, 'node_modules', name);
      if (fs.existsSync(path.join(dependency, 'package.json'))) visitNpm(dependency);
      else if (!(name in (pkg.optionalDependencies ?? {})) && !pkg.peerDependenciesMeta?.[name]?.optional) throw new Error(`Missing installed dependency ${name} of ${pkg.name}. Run npm ci.`);
    }
  }
  visitNpm(path.join(root, 'packages/editor'));

  const target = process.arch === 'arm64' ? 'aarch64-apple-darwin' : 'x86_64-apple-darwin';
  const metadata = JSON.parse(execFileSync('cargo', ['metadata', '--format-version', '1', '--locked', '--offline', '--filter-platform', target, '--features', 'lino-ffi/bindgen'], { cwd: root, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 }));
  const packages = new Map(metadata.packages.map(pkg => [pkg.id, pkg]));
  const nodes = new Map(metadata.resolve.nodes.map(node => [node.id, node]));
  const reachable = new Set();
  function visitCargo(id) {
    if (reachable.has(id)) return;
    reachable.add(id);
    for (const dependency of nodes.get(id).deps) visitCargo(dependency.pkg);
  }
  for (const id of metadata.workspace_members) visitCargo(id);
  for (const id of [...reachable].sort()) {
    const pkg = packages.get(id);
    if (!pkg.source) continue;
    const directory = path.dirname(pkg.manifest_path);
    const files = licenseFiles(directory);
    if (pkg.license_file) files.push(path.resolve(directory, pkg.license_file));
    const vcsPath = path.join(directory, '.cargo_vcs_info.json');
    const revision = fs.existsSync(vcsPath) ? JSON.parse(fs.readFileSync(vcsPath, 'utf8')).git?.sha1 : undefined;
    const supplement = supplements.find(entry => entry.repository === pkg.repository && entry.revision === revision);
    if (files.length === 0 && supplement) {
      files.push(path.join(__dirname, 'licenses', supplement.file));
      // New objc2 releases retain the MIT declaration in LICENSE.md; include
      // the upstream MIT grant retained before that declaration was reorganized.
      if (supplement.repository === 'https://github.com/madsmtm/objc2') files.push(path.join(__dirname, 'licenses', 'objc2-MIT.LICENSE'));
    }
    let source = revision && pkg.repository?.startsWith('https://github.com/')
      ? `${pkg.repository}/tree/${revision}`
      : `https://crates.io/crates/${pkg.name}/${pkg.version}`;
    if (files.some(file => path.basename(file) === 'objc2-MIT.LICENSE')) source += `\nHistorical MIT grant: ${objc2MitSource}`;
    add(`Cargo ${pkg.name}@${pkg.version} (${pkg.license ?? 'see text'})`, source, files);
  }

  fs.mkdirSync(destination, { recursive: true });
  fs.copyFileSync(path.join(root, 'node_modules/katex/LICENSE'), path.join(destination, 'KaTeX.txt'));
  for (const file of ['LICENSE', 'NOTICE.md']) fs.copyFileSync(path.join(root, file), path.join(destination, file));
  const sections = [...texts].map(([content, item]) => `--- License text ${item.number} ---\n${item.owners.join('\n')}\n\n${content}`);
  fs.writeFileSync(path.join(destination, 'THIRD-PARTY.txt'), [
    'Lino third-party notices',
    'Includes installed editor dependencies and Cargo dependencies used by the application and its build tools. Source links identify the corresponding upstream releases. These components retain their original licenses; the project MIT license does not replace them.',
    ...notices,
    ...sections,
  ].join('\n\n') + '\n');
}

module.exports = { writeLicenses };
