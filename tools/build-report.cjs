// Render original research prose. This tool does not access or run Typora.
const fs=require('node:fs'),path=require('node:path'),MarkdownIt=require('markdown-it');
const root=path.resolve(__dirname,'..'),md=new MarkdownIt({html:false,linkify:false});
const text=fs.readFileSync(path.join(root,'docs/report.zh-CN.md'),'utf8');
const headings=[],used=new Set();
md.core.ruler.push('heading_ids',state=>{
  state.tokens.forEach((t,i)=>{
    if(t.type!=='heading_open')return;
    const label=state.tokens[i+1].content;
    let base=label.toLowerCase().replace(/[^\p{L}\p{N}]+/gu,'-').replace(/^-|-$/g,''),id=base,n=1;
    while(used.has(id))id=`${base}-${n++}`;used.add(id);t.attrSet('id',id);
    if(t.tag==='h2')headings.push({id,label});
  });
});
md.renderer.rules.table_open=()=>'<div class="table-wrap"><table>\n';
md.renderer.rules.table_close=()=>'</table></div>\n';
const esc=s=>md.utils.escapeHtml(s);
const bridges=JSON.parse(fs.readFileSync(path.join(root,'data/bridges.json'),'utf8'));
const bridgeTable='<h2 id="bridge-index">桥接接口索引</h2><p>原生候选是静态字面量端点配对，不代表运行证明。未匹配记录仍保留。</p><div class="table-wrap"><table><thead><tr><th>方法</th><th>JS API</th><th>方向</th><th>JS 字符位置</th><th>原生候选</th></tr></thead><tbody>'+bridges.map(b=>'<tr>'+[b.method,b.javascript_api,b.direction,b.javascript_char_offset,b.native_candidates.map(n=>n.function+' @ '+n.instruction).join('; ')||'当前保守索引未匹配'].map(v=>'<td>'+esc(String(v))+'</td>').join('')+'</tr>').join('')+'</tbody></table></div>';
const body=md.render(text)+bridgeTable;
headings.push({id:'bridge-index',label:'桥接接口索引'});
const nav=headings.map(h=>`<a href="#${esc(h.id)}">${esc(h.label)}</a>`).join('');
const sample=JSON.parse(fs.readFileSync(path.join(root,'data/sample.json'),'utf8'));
const page=`<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="description" content="Typora's editor, document model and macOS native bridges, explained with static evidence."><title>open-typora · Typora architecture report</title><link rel="stylesheet" href="assets/report.css"></head><body><aside><strong><a href="https://github.com/yruichen/open-typora">open-typora ↗</a></strong>${nav}<a href="../README.md">English overview</a></aside><main><header><p><a href="https://github.com/yruichen/open-typora">GitHub repository ↗</a> · <a href="report.zh-CN.md">Markdown report</a> · <a href="reproduce.md">Reproduce</a></p><span class="tag">Typora ${esc(sample.version)}</span><span class="tag">Static evidence</span><span class="tag">83 modules</span><input id="query" aria-label="筛选模块和接口表" placeholder="筛选表格，例如：Pandoc、UndoManager、quickOpen.query"></header><article>${body}</article><footer><p>Original research and tooling: MIT. Typora remains the property of its respective owners. <a href="https://github.com/morluto/rea">REA</a> supported the investigation.</p></footer></main><script src="assets/report.js"></script></body></html>`;
fs.writeFileSync(path.join(root,'docs/index.html'),page);
console.log(`Built docs/index.html (${Buffer.byteLength(page)} bytes, ${headings.length} sections).`);
