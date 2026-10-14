import MarkdownIt, { type Token } from 'markdown-it';
import footnotes from 'markdown-it-footnote';
import DOMPurify from 'dompurify';
import { EditorState } from '@codemirror/state';
import { parser, GFM } from '@lezer/markdown';
import { highlightTree, classHighlighter } from '@lezer/highlight';
import type { SyntaxNode } from '@lezer/common';
import type { ExportSource } from '@lino/protocol/generated/ExportSource';
import { sourceDocument } from '../transactions/line-endings.ts';
import { mathSyntax } from '../features/media/syntax.ts';
import { sourceNode } from '../features/media/model.ts';
import { referenceSyntax } from '../features/references/syntax.ts';
import { anchoredHeadings } from '../features/references/model.ts';
import { languageForCode } from '../features/code/languages.ts';
import { previewRenderer, type PreviewRenderer, type RenderInput } from '../renderers/previews.ts';
import { t } from '../localization/index.ts';
import { exportStyle } from './style.ts';
import { underlineReading } from '../features/markdown/reading.ts';

interface Slot { input?: RenderInput; html?: string; block: boolean }
interface FormatTrie { children: Map<string, FormatTrie>; format?: { tag: string; content: string; length: number } }
const inlineTags: Record<string, string> = { Highlight: 'mark', Superscript: 'sup', Subscript: 'sub' };
const safeURL = (url: string) => !/^[\s\u0000-\u001f]*\/\//.test(url) && (!/^[a-z][a-z\d+.-]*:/i.test(url) || /^(https?:|mailto:|data:image\/)/i.test(url));
const escape = (value: string) => value.replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]!);
/** One immutable render plan serves HTML and native print/PDF. */
export class ExportPlan {
  readonly source: ExportSource;
  readonly images: string[];
  private readonly markdown = new MarkdownIt({ html: false, linkify: true, typographer: false });
  private readonly tokens: Token[];
  private readonly slots = new Map<string, Slot>();
  private readonly environment = {};
  private readonly abort = new AbortController();
  private readonly renderer: PreviewRenderer;
  constructor(source: ExportSource, renderer: PreviewRenderer = previewRenderer) {
    this.source = source; this.renderer = renderer;
    const md = this.markdown; underlineReading(md); md.use(footnotes); md.disable('footnote_inline');
    const state = EditorState.create({ doc: sourceDocument(source.text).doc });
    const tree = parser.configure([GFM, mathSyntax, referenceSyntax]).parse(state.doc.toString());
    const headings: { from: number; to: number; title: string; level: number }[] = [];
    tree.iterate({ enter(node) {
      if (['FrontMatter', 'FootnoteDefinition', 'FencedCode', 'CodeBlock', 'HTMLBlock'].includes(node.name)) return false;
      const match = /^(?:ATX|Setext)Heading([1-6])$/.exec(node.name); if (!match) return;
      let from = node.from, to = node.to;
      for (let child = node.node.firstChild; child; child = child.nextSibling) if (child.name === 'HeaderMark') {
        if (child.from === from) from = child.to; else to = child.from;
      }
      headings.push({ from: node.from, to: node.to, level: Number(match[1]), title: state.sliceDoc(from, to).trim() }); return false;
    } });
    const outline = anchoredHeadings(headings), anchors = new Map(outline.map(entry => [state.doc.lineAt(entry.from).number - 1, entry.anchor]));
    const prefix = crypto.randomUUID(), seenNotes = new Set<string>();
    const formats: FormatTrie = { children: new Map() };
    md.inline.ruler.before('emphasis', 'lino_format', (inline, silent) => {
      let node = formats, found: FormatTrie['format'];
      for (let pos = inline.pos; pos < inline.posMax; pos++) {
        const next = node.children.get(inline.src[pos]); if (!next) break;
        node = next; if (node.format) found = node.format;
      }
      if (!found) return false;
      if (!silent) {
        const token = inline.push('lino_format', found.tag, 0); token.children = [];
        md.inline.parse(found.content, md, inline.env, token.children);
      }
      inline.pos += found.length; return true;
    });
    md.renderer.rules.lino_format = (tokens, index, options, env, renderer) => `<${tokens[index].tag}>${renderer.renderInline(tokens[index].children!, options, env)}</${tokens[index].tag}>`;
    const slot = (node: SyntaxNode, value: Slot) => {
      const id = prefix + '-' + this.slots.size; this.slots.set(id, value);
      return `[lino-export](lino-slot:${id})` + '\n'.repeat(state.sliceDoc(node.from, node.to).split('\n').length - 1);
    };
    const rewrite = (node: SyntaxNode): string => {
      if (node.name === 'FrontMatter') return '\n'.repeat(state.sliceDoc(node.from, node.to).split('\n').length - 1);
      if (node.name === 'FootnoteDefinition') {
        const label = node.getChild('FootnoteLabel'), id = label && state.sliceDoc(label.from + 2, label.to - 1);
        if (id && seenNotes.has(id)) return '\n'.repeat(state.sliceDoc(node.from, node.to).split('\n').length - 1);
        if (id) seenNotes.add(id);
      }
      if (node.name === 'DocumentTOC') return slot(node, { block: true, html: `<nav class="contents" aria-label="${escape(t('references.toc'))}"><ul>${outline.map(entry => `<li class="level-${entry.level}"><a href="#${escape(entry.anchor)}">${escape(entry.title)}</a></li>`).join('')}</ul></nav>` });
      if (['InlineMath', 'MathBlock', 'FencedCode'].includes(node.name)) {
        const preview = sourceNode(state, node);
        if (preview && preview.kind !== 'image') {
          if (preview.tooLarge) throw new Error(t('export.limit'));
          return slot(node, { block: preview.block, input: { kind: preview.kind, text: preview.text, block: preview.block, dark: source.preferences.theme === 'dark' } });
        }
        return state.sliceDoc(node.from, node.to);
      }
      if (['InlineCode', 'CodeBlock', 'HTMLBlock', 'HTMLTag', 'Image', 'LinkReference'].includes(node.name)) return state.sliceDoc(node.from, node.to);
      const tag = inlineTags[node.name]; let result = '', position = node.from;
      for (let child = node.firstChild; child; child = child.nextSibling) {
        result += state.sliceDoc(position, child.from);
        result += rewrite(child);
        position = child.to;
      }
      result += state.sliceDoc(position, node.to);
      if (tag) {
        const marks = node.getChildren(node.name === 'Highlight' ? 'HighlightMark' : 'ScriptMark');
        if (marks.length === 2) {
          let trie = formats;
          for (let position = 0; position < result.length; position++) {
            const char = result[position];
            let next = trie.children.get(char); if (!next) { next = { children: new Map() }; trie.children.set(char, next); } trie = next;
          }
          trie.format = { tag, content: result.slice(marks[0].to - marks[0].from, result.length - (marks[1].to - marks[1].from)), length: result.length };
        }
      }
      return result;
    };
    this.tokens = md.parse(rewrite(tree.topNode), this.environment);
    const walk = (tokens: Token[], action: (token: Token) => void) => { for (const token of tokens) { action(token); if (token.children) walk(token.children, action); } };
    const images = new Set<string>();
    walk(this.tokens, token => {
      if (token.type === 'image') {
        const url = String(token.attrGet('src') ?? '');
        if (/^https?:/i.test(url)) throw new Error(t('export.remoteImage'));
        if (!safeURL(url)) throw new Error(t('export.unsafeURL'));
        if (!/^data:image\//i.test(url)) images.add(url);
      }
      if (token.type === 'heading_open') { const anchor = token.map && anchors.get(token.map[0]); if (anchor) token.attrSet('id', anchor); }
    });
    this.images = [...images];
    md.renderer.rules.fence = (tokens, index) => {
      const token = tokens[index], language = languageForCode(token.info), spans: string[] = []; let cursor = 0;
      if (language) highlightTree(language.parser.parse(token.content), classHighlighter, (from, to, classes) => {
        spans.push(escape(token.content.slice(cursor, from)), `<span class="${escape(classes)}">${escape(token.content.slice(from, to))}</span>`); cursor = to;
      });
      spans.push(escape(token.content.slice(cursor)));
      return `<pre class="${source.preferences.code_wrap ? 'wrap' : ''}"><code>${spans.join('')}</code></pre>\n`;
    };
    md.renderer.rules.lino_task = (tokens, index) => `<input type="checkbox" disabled${tokens[index].content === 'x' ? ' checked' : ''}>`;
    for (let i = 2; i < this.tokens.length; i++) {
      const token = this.tokens[i];
      if (token.type !== 'inline' || this.tokens[i - 1].type !== 'paragraph_open' || this.tokens[i - 2].type !== 'list_item_open') continue;
      const first = token.children?.[0], match = first?.type === 'text' && /^\[([ xX])\] /.exec(first.content);
      if (match && first) {
        first.content = first.content.slice(4);
        const task = new (first.constructor as new(type: string, tag: string, nesting: 0) => Token)('lino_task', '', 0);
        task.content = match[1].toLowerCase(); token.children!.unshift(task);
      }
    }
  }
  cancel(): void { this.abort.abort(); }
  async render(resources: Record<string, string>, mathCSS = ''): Promise<string> {
    if (this.abort.signal.aborted) throw new Error(t('export.cancelled'));
    const md = this.markdown, imageRule = md.renderer.rules.image!;
    md.renderer.rules.image = (tokens, index, options, environment, renderer) => {
      const url = String(tokens[index].attrGet('src')!);
      if (!/^data:image\//i.test(url)) {
        const data = resources[url];
        if (!data || !/^data:image\/[a-z\d.+-]+;base64,[a-z\d+/=]+$/i.test(data)) throw new Error(t('export.missingImage', { source: url }));
        tokens[index].attrSet('src', data);
      }
      return imageRule(tokens, index, options, environment, renderer);
    };
    const container = document.createElement('article'); container.innerHTML = md.renderer.render(this.tokens, md.options, this.environment);
    let remaining = this.slots.size;
    while (true) {
      const placeholders = [...container.querySelectorAll<HTMLAnchorElement>('a[href^="lino-slot:"]')];
      if (!placeholders.length) break;
      for (const placeholder of placeholders) {
        if (--remaining < 0) throw new Error(t('export.invalid'));
        const entry = this.slots.get(placeholder.getAttribute('href')!.slice('lino-slot:'.length)); if (!entry) throw new Error(t('export.invalid'));
        const html = entry.html ?? (await this.renderer.request(entry.input!, this.abort.signal)).html;
        if (this.abort.signal.aborted) throw new Error(t('export.cancelled'));
        const holder = document.createElement(entry.block ? 'div' : 'span'); holder.innerHTML = html;
        if (entry.block && placeholder.parentElement?.tagName === 'P' && placeholder.parentElement.textContent?.trim() === placeholder.textContent) placeholder.parentElement.replaceWith(holder);
        else placeholder.replaceWith(holder);
      }
    }
    // Generated namespaces are allowed; user HTML remains escaped literal text.
    container.innerHTML = DOMPurify.sanitize(container.innerHTML, { USE_PROFILES: { html: true, svg: true, svgFilters: true, mathMl: true }, FORBID_TAGS: ['script', 'iframe', 'object', 'embed', 'form'], ALLOW_DATA_ATTR: false });
    for (const link of container.querySelectorAll('a')) if (!safeURL(link.getAttribute('href') ?? '')) link.removeAttribute('href');
    for (const image of container.querySelectorAll('img')) if (!/^data:image\//i.test(image.getAttribute('src') ?? '')) throw new Error(t('export.invalid'));
    const title = this.source.label ?? t('document.untitled');
    const mathStyle = [...this.slots.values()].some(slot => slot.input?.kind === 'math') ? mathCSS : '';
    const html = `<!doctype html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:"><title>${escape(title)}</title><style>${exportStyle(this.source.preferences).replace(/<\/style/gi, '<\\/style')}\n${mathStyle.replace(/<\/style/gi, '<\\/style')}</style></head><body>${container.outerHTML}</body></html>`;
    if (html.length > 32 * 1024 * 1024) throw new Error(t('export.limit'));
    return html;
  }
}
