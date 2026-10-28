import MarkdownIt from 'markdown-it';
import { EditorState } from '@codemirror/state';
import { parser, GFM } from '@lezer/markdown';
import { mathSyntax } from '../media/syntax.ts';
import { sourceNode } from '../media/model.ts';
import { previewRenderer, type PreviewRenderer } from '../../renderers/previews.ts';
import { formatError } from '../../localization/errors.ts';
import { underlineReading } from './reading.ts';
import { replaceParsedHTML, sanitizeHTML } from './html.ts';

// Derived reading content. Input and history remain in the owning editor.
const markdown = new MarkdownIt({ html: true, linkify: false, typographer: false });
underlineReading(markdown);
// Images in inline reading content must not initiate unscoped or remote requests.
markdown.renderer.rules.image = (tokens, index) => markdown.utils.escapeHtml(tokens[index].content);
markdown.inline.ruler.before('escape', 'inline_math', (state, silent) => {
  const math: InlineMath | undefined = state.src === state.env.source && state.env.math instanceof Map ? state.env.math.get(state.pos) : undefined;
  if (!math) return false;
  if (!silent) { const token = state.push('inline_math', 'span', 0); token.meta = math; }
  state.pos = math.to; return true;
});
markdown.renderer.rules.inline_math = (tokens, index) => `<span class="ot-inline-math" data-math-from="${tokens[index].meta!.from}"></span>`;
interface InlineMath extends Record<string, unknown> { from: number; to: number; text: string }
interface InlineEnvironment extends Record<PropertyKey, unknown> { source: string; math: Map<number, InlineMath> }
const mathParser = parser.configure([GFM, mathSyntax]);

function inlineContent(source: string): { html: string; math: Map<number, InlineMath> } {
  const environment: InlineEnvironment = { source, math: new Map() };
  if (source.includes('$')) {
    const state = EditorState.create({ doc: source });
    mathParser.parse(source).iterate({ enter(node) {
      if (node.name === 'InlineCode') return false;
      if (node.name !== 'InlineMath') return;
      const preview = sourceNode(state, node.node);
      if (preview) environment.math.set(node.from, { from: node.from, to: node.to, text: preview.text });
      return false;
    } });
  }
  return { html: sanitizeHTML(markdown.renderInline(source, environment), true), math: environment.math };
}

export function presentInline(element: HTMLElement, source: string, dark: boolean, measure: () => void): () => void {
  const abort = new AbortController(), content = inlineContent(source);
  replaceParsedHTML(element, content.html);
  for (const slot of element.querySelectorAll<HTMLElement>('.ot-inline-math')) {
    const math = content.math.get(Number(slot.dataset.mathFrom))!;
    slot.textContent = `$${math.text}$`;
    const input = { kind: 'math' as const, text: math.text, block: false, dark };
    const report = (error: unknown) => { slot.dataset.previewState = 'error'; slot.title = formatError(error); };
    try {
      const cached = previewRenderer.cached(input) ?? previewRenderer.immediate(input);
      if (cached) { replaceParsedHTML(slot, cached.html); continue; }
    } catch (error) { report(error); continue; }
    queueMicrotask(() => {
      if (abort.signal.aborted || !slot.isConnected) return;
      void previewRenderer.request(input, abort.signal).then(result => {
        if (abort.signal.aborted || !slot.isConnected) return;
        replaceParsedHTML(slot, result.html); measure();
      }, error => {
        if (abort.signal.aborted || !slot.isConnected) return;
        report(error); measure();
      });
    });
  }
  return () => abort.abort();
}

/** Export uses the same inline dialect and its own renderer/cancellation. */
export async function inlineHTML(source: string, dark: boolean, renderer: PreviewRenderer, signal: AbortSignal): Promise<string> {
  const content = inlineContent(source), element = document.createElement('span');
  replaceParsedHTML(element, content.html);
  for (const slot of element.querySelectorAll<HTMLElement>('.ot-inline-math')) {
    const math = content.math.get(Number(slot.dataset.mathFrom))!;
    const result = await renderer.request({ kind: 'math', text: math.text, block: false, dark }, signal);
    if (signal.aborted) throw new Error('Inline rendering cancelled');
    replaceParsedHTML(slot, result.html);
  }
  return element.innerHTML;
}
