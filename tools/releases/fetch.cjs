// Release automation uses its repository-scoped GITHUB_TOKEN. The app never calls this API.
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const output = process.argv[2];
if (!output) throw Error('Pass the output release JSON path.');
const releases = [];
for (let page = 1; page <= 10; page++) {
  const batch = JSON.parse(execFileSync('gh', ['api', `repos/yruichen/lino/releases?per_page=100&page=${page}`], { encoding: 'utf8', timeout: 30000, maxBuffer: 16 * 1024 * 1024 }));
  if (!Array.isArray(batch)) throw Error('Invalid GitHub release response.');
  releases.push(...batch);
  if (batch.length < 100) break;
  if (page === 10) throw Error('Release history exceeds the publication limit; review retention before publishing.');
}
fs.mkdirSync(path.dirname(output), { recursive: true });
fs.writeFileSync(output, JSON.stringify(releases));
