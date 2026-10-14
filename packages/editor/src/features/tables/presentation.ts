import MarkdownIt from 'markdown-it';
import { EditorState } from '@codemirror/state';
import { parser, GFM } from '@lezer/markdown';
import { mathSyntax } from '../media/syntax.ts';
import { sourceNode } from '../media/model.ts';
import { previewRenderer } from '../../renderers/previews.ts';
import { formatError } from '../../localization/errors.ts';
import { underlineReading } from '../markdown/reading.ts';

// Derived reading content. Input and history remain in the owning editor.
const markdown = new MarkdownIt({ html: false, linkify: false, typographer: false });
underlineReading(markdown);
// Images in a reading cell must not initiate unscoped or remote requests.
markdown.renderer.rules.image = (tokens, index) => markdown.utils.escapeHtml(tokens[index].content);
markdown.inline.ruler.before('escape', 'cell_math', (state, silent) => {
  const math: CellMath | undefined = state.src === state.env.source && state.env.math instanceof Map ? state.env.math.get(state.pos) : undefined;
  if (!math) return false;
  if (!silent) { const token = state.push('cell_math', 'span', 0); token.meta = math; }
  state.pos = math.to; return true;
});
markdown.renderer.rules.cell_math = (tokens, index) => `<span class="table-cell-math" data-math-from="${tokens[index].meta!.from}"></span>`;
interface CellMath extends Record<string, unknown> { from: number; to: number; text: string }
interface CellEnvironment extends Record<PropertyKey, unknown> { source: string; math: Map<number, CellMath> }
const mathParser = parser.configure([GFM, mathSyntax]);

export function presentCell(element: HTMLElement, source: string, dark: boolean, measure: () => void): () => void {
  const abort = new AbortController(), environment: CellEnvironment = { source, math: new Map() };
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
  element.innerHTML = markdown.renderInline(source, environment);
  for (const slot of element.querySelectorAll<HTMLElement>('.table-cell-math')) {
    const math = environment.math.get(Number(slot.dataset.mathFrom))!;
    slot.textContent = `$${math.text}$`;
    queueMicrotask(() => {
      if (abort.signal.aborted || !slot.isConnected) return;
      void previewRenderer.request({ kind: 'math', text: math.text, block: false, dark }, abort.signal).then(result => {
        if (abort.signal.aborted || !slot.isConnected) return;
        slot.innerHTML = result.html; measure();
      }, error => {
        if (abort.signal.aborted || !slot.isConnected) return;
        slot.dataset.previewState = 'error'; slot.title = formatError(error); measure();
      });
    });
  }
  return () => abort.abort();
}
