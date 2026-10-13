// Enforce package boundaries. This does not prove behavior or module-level purity.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');

function validateGraph(nodes, rules, platformPackages = []) {
  assert.deepEqual(Object.keys(nodes).sort(), Object.keys(rules).sort(), 'Packages and architecture policy differ');
  for (const [name, node] of Object.entries(nodes)) {
    const rule = rules[name];
    assert.equal(node.path, rule.path, `Unexpected location for ${name}`);
    for (const dep of node.dependencies) {
      if (rules[dep.name]) {
        assert(rule.allow.includes(dep.name), `Forbidden dependency: ${name} -> ${dep.name}`);
      } else {
        assert(!dep.local, `Unregistered local dependency: ${name} -> ${dep.name}`);
        assert(!dep.name.startsWith('open-typora-') && !dep.name.startsWith('@open-typora/'), `Unknown internal package: ${dep.name}`);
      }
      if (!rule.platform_dependencies) {
        assert(!platformPackages.includes(dep.name) && !/^(objc2-|webview2-)/.test(dep.name), `Platform dependency in ${name}: ${dep.name}`);
      }
      assert(!(rule.forbid || []).includes(dep.name), `Forbidden external dependency in ${name}: ${dep.name}`);
    }
  }
  const visiting = new Set(), visited = new Set();
  function visit(name) {
    assert(!visiting.has(name), `Dependency cycle through ${name}`);
    if (visited.has(name)) return;
    visiting.add(name);
    for (const dep of nodes[name].dependencies) if (nodes[dep.name]) visit(dep.name);
    visiting.delete(name);
    visited.add(name);
  }
  for (const name of Object.keys(nodes)) visit(name);
}

function main() {
  const policy = JSON.parse(fs.readFileSync(path.join(__dirname, 'architecture-dependencies.json'), 'utf8'));
  const result = spawnSync('cargo', ['metadata', '--format-version', '1', '--no-deps', '--locked'], { cwd: root, encoding: 'utf8' });
  if (result.error) throw new Error(`Cannot run cargo: ${result.error.message}. Check your Rust PATH.`);
  assert.equal(result.status, 0, result.stderr);
  const metadata = JSON.parse(result.stdout), members = new Set(metadata.workspace_members), rust = {};
  for (const pkg of metadata.packages.filter(p => members.has(p.id))) {
    rust[pkg.name] = {
      path: path.relative(root, path.dirname(pkg.manifest_path)).split(path.sep).join('/'),
      dependencies: pkg.dependencies.map(d => ({ name: d.name, local: Boolean(d.path) })),
    };
  }
  validateGraph(rust, policy.rust, policy.platform_packages);
  const frontend = {};
  const workspace = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
  assert.deepEqual(workspace.workspaces.slice().sort(), Object.values(policy.frontend).map(p => p.path).sort(), 'Frontend workspace and policy differ');
  for (const rule of Object.values(policy.frontend)) {
    const pkg = JSON.parse(fs.readFileSync(path.join(root, rule.path, 'package.json'), 'utf8'));
    frontend[pkg.name] = { path: rule.path, dependencies: Object.entries({ ...pkg.dependencies, ...pkg.devDependencies, ...pkg.peerDependencies, ...pkg.optionalDependencies }).map(([name, version]) => ({ name, local: /^(file:|link:)/.test(version) })) };
  }
  validateGraph(frontend, policy.frontend);
  console.log(`Architecture checked: ${Object.keys(rust).length} Rust crates, ${Object.keys(frontend).length} frontend packages; allowed edges and acyclic graph.`);
}

module.exports = { validateGraph };
if (require.main === module) main();
