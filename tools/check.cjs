const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),read=name=>JSON.parse(fs.readFileSync(path.join(root,name),'utf8'));
const sample=read('data/sample.json'),modules=read('data/modules.json'),bridges=read('data/bridges.json'),native=read('data/native-methods.json');
assert.equal(modules.modules.length,sample.counts.javascript_modules);
assert.equal(new Set(modules.modules.map(m=>m.id)).size,modules.modules.length);
assert.equal(bridges.length,sample.counts.javascript_bridge_callsites);
assert.equal(bridges.filter(b=>b.native_candidates.length).length,sample.counts.literal_endpoint_matched_js_callsites);
assert.equal(native.classes.length,sample.counts.native_defined_classes);
assert.equal(native.methods.length,sample.counts.native_method_implementations);
const ids=new Set(modules.modules.map(m=>m.id));
for(const m of modules.modules){
  assert(m.char_end>m.char_start,`Invalid range for module ${m.id}`);
  for(const id of m.dependencies)assert(ids.has(id),`Unknown dependency ${id}`);
}
const forbidden=/(?:\/Users\/[^\s/]+|\/private\/var\/folders\/|\/tmp\/rea-|gh[opusr]_[A-Za-z0-9]{20,}|sk-proj-[A-Za-z0-9]{20,}|REA_TOKEN\s*=)/;
let scanned=0;
function walk(dir){for(const e of fs.readdirSync(dir,{withFileTypes:true})){
  if(['.git','.local','node_modules'].includes(e.name))continue;
  const full=path.join(dir,e.name);
  assert(!e.isSymbolicLink(),'Publication must not contain symlinks');
  if(e.isDirectory()){walk(full);continue;}
  assert(!/\.(zip|dmg|dylib|hop|hopdb)$/.test(e.name),'Target artifact in publication');
  const text=fs.readFileSync(full,'utf8');
  assert(!forbidden.test(text),`Private path or credential pattern in ${path.relative(root,full)}`);
  if(full.endsWith('.json'))JSON.parse(text);
  scanned++;
}}
walk(root);
const page=fs.readFileSync(path.join(root,'docs/index.html'),'utf8');
const idsInPage=new Set([...page.matchAll(/\bid="([^"]+)"/g)].map(m=>m[1]));
for(const match of page.matchAll(/\b(?:href|src)="([^"]+)"/g)){
  const href=match[1];if(/^https?:/.test(href))continue;
  if(href.startsWith('#'))assert(idsInPage.has(href.slice(1)),`Missing anchor ${href}`);
  else assert(fs.existsSync(path.resolve(root,'docs',href.split('#')[0])),`Missing local link ${href}`);
}
console.log(`Checked ${scanned} public files, module dependencies, counts, report links and publication exclusions.`);
