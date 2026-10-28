import { syntaxTree } from '@codemirror/language';
import { StateEffect, StateField, type EditorState } from '@codemirror/state';
import { Decoration, EditorView, ViewPlugin, WidgetType, type DecorationSet, type ViewUpdate } from '@codemirror/view';
import { compositionState, modeState } from '../source-mode/state.ts';
import { presentationSelection } from '../../controls/pointer.ts';
import { HTMLWidget, inlineHTMLRange } from './html.ts';

const hiddenMarks = new Set(['HeaderMark', 'QuoteMark', 'EmphasisMark', 'StrikethroughMark', 'CodeMark', 'HighlightMark', 'ScriptMark']);
const inlineStyles: Readonly<Record<string, string>> = { Highlight: 'ot-highlight', Superscript: 'ot-superscript', Subscript: 'ot-subscript', FrontMatter: 'ot-frontmatter', FootnoteDefinition: 'ot-footnote-definition' };
const refreshHTMLBlocks = StateEffect.define<null>();

class RuleWidget extends WidgetType {
  override toDOM(): HTMLElement { const rule = document.createElement('hr'); rule.className = 'ot-horizontal-rule'; return rule; }
  override ignoreEvent(): boolean { return false; }
}
class BulletWidget extends WidgetType {
  override toDOM(): HTMLElement { const bullet = document.createElement('span'); bullet.className = 'ot-list-bullet'; bullet.textContent = '•'; bullet.setAttribute('aria-hidden', 'true'); return bullet; }
  override ignoreEvent(): boolean { return false; }
}
interface HTMLBlockRange { from: number; to: number }
interface HTMLBlockProjection { ranges: readonly HTMLBlockRange[]; decorations: DecorationSet }
function collectHTMLBlockRanges(state: EditorState): HTMLBlockRange[] {
  const ranges: HTMLBlockRange[] = [];
  syntaxTree(state).iterate({ enter(node) {
    if (node.name !== 'HTMLBlock') return;
    ranges.push({ from: node.from, to: node.to }); return false;
  } });
  return ranges;
}
function htmlBlockProjection(state: EditorState, ranges: readonly HTMLBlockRange[]): HTMLBlockProjection {
  if (state.field(modeState) === 'source') return { ranges, decorations: Decoration.none };
  const decorations: ReturnType<Decoration['range']>[] = [];
  for (const range of ranges) {
    const active = presentationSelection(state).ranges.some(selection => selection.from <= range.to && selection.to >= range.from);
    if (!active) decorations.push(Decoration.replace({ block: true, widget: new HTMLWidget(state.sliceDoc(range.from, range.to), true, range.from, range.to) }).range(range.from, range.to));
  }
  return { ranges, decorations: Decoration.set(decorations, true) };
}

export const htmlBlockPresentation = StateField.define<HTMLBlockProjection>({
  create: state => htmlBlockProjection(state, collectHTMLBlockRanges(state)),
  update(value, transaction) {
    const syntaxChanged = syntaxTree(transaction.startState) !== syntaxTree(transaction.state);
    if (transaction.docChanged || transaction.effects.some(effect => effect.is(refreshHTMLBlocks)) || syntaxChanged)
      return htmlBlockProjection(transaction.state, collectHTMLBlockRanges(transaction.state));
    if (transaction.selection !== undefined || transaction.startState.field(modeState) !== transaction.state.field(modeState)
      || transaction.startState.field(compositionState) !== transaction.state.field(compositionState)) return htmlBlockProjection(transaction.state, value.ranges);
    return value;
  },
  provide: field => EditorView.decorations.from(field, value => value.decorations),
});

function decorations(view: EditorView): DecorationSet {
  if (view.state.field(modeState) === 'source') return Decoration.none;
  const ranges: ReturnType<Decoration['range']>[] = [];
  const htmlRanges: { from: number; to: number }[] = [];
  const source = view.state.doc.toString();
  const coveredByHTML = (from: number, to: number) => htmlRanges.some(range => range.from < to && range.to > from);
  const tree = syntaxTree(view.state), lines = new Map<number, Set<string>>();
  const active = (from: number, to: number) => presentationSelection(view.state).ranges.some(range => range.from <= to && range.to >= from);
  const styleLine = (from: number, name: string) => {
    const at = view.state.doc.lineAt(from).from, classes = lines.get(at) ?? new Set<string>(); classes.add(name); lines.set(at, classes);
  };
  for (const visible of view.visibleRanges) tree.iterate({ from: visible.from, to: visible.to, enter(node) {
    if (node.name === 'HTMLBlock') return false;
    if (node.name === 'HTMLTag') {
      const range = inlineHTMLRange(source, node.from, node.to);
      if (range && !coveredByHTML(range.from, range.to)) {
        htmlRanges.push(range);
        if (!active(range.from, range.to)) ranges.push(Decoration.replace({ widget: new HTMLWidget(source.slice(range.from, range.to), false, range.from, range.to) }).range(range.from, range.to));
      }
      return false;
    }
    if (coveredByHTML(node.from, node.to) || ['Table', 'FencedCode', 'CodeBlock', 'MathBlock', 'InlineMath', 'Image'].includes(node.name)) return false;
    const heading = /^(?:ATX|Setext)Heading([1-6])$/.exec(node.name);
    if (heading) styleLine(node.from, `ot-heading ot-heading-${heading[1]}`);
    if (node.name === 'Blockquote') {
      const first = view.state.doc.lineAt(Math.max(node.from, visible.from)).number;
      const last = view.state.doc.lineAt(Math.min(node.to, visible.to)).number;
      for (let line = first; line <= last; line++) styleLine(view.state.doc.line(line).from, 'ot-quote-line');
    }
    if (node.name === 'HorizontalRule' && !active(node.from, node.to)) {
      ranges.push(Decoration.replace({ widget: new RuleWidget() }).range(node.from, node.to)); return false;
    }
    if (node.name === 'ListMark' && !active(node.node.parent!.from, node.node.parent!.to) && /^[-+*]$/.test(view.state.sliceDoc(node.from, node.to))) {
      ranges.push(Decoration.replace({ widget: new BulletWidget() }).range(node.from, node.to)); return;
    }
    const style = inlineStyles[node.name];
    if (style) ranges.push(Decoration.mark({ class: style }).range(node.from, node.to));
    if (!hiddenMarks.has(node.name)) return;
    const parent = node.node.parent!;
    if (active(parent.from, parent.to)) return;
    let to = node.to;
    if (node.name === 'HeaderMark' || node.name === 'QuoteMark') {
      const line = view.state.doc.lineAt(node.from);
      if (node.name === 'HeaderMark' && parent.name.startsWith('Setext')) styleLine(node.from, 'ot-heading-underline');
      else if (view.state.sliceDoc(to, to + 1) === ' ' && to < line.to) to++;
    }
    ranges.push(Decoration.replace({}).range(node.from, to));
  } });
  for (const [from, classes] of lines) ranges.push(Decoration.line({ class: [...classes].join(' ') }).range(from));
  return Decoration.set(ranges, true);
}

export const markdownPresentation = ViewPlugin.fromClass(class {
  decorations: DecorationSet;
  private refreshQueued = false;
  private hasHTML: boolean;
  constructor(view: EditorView) { this.decorations = decorations(view); this.hasHTML = view.state.doc.toString().includes('<'); this.scheduleHTMLRefresh(view); }
  private scheduleHTMLRefresh(view: EditorView): void {
    if (this.refreshQueued || !this.hasHTML) return;
    this.refreshQueued = true;
    queueMicrotask(() => {
      this.refreshQueued = false;
      if (view.dom.isConnected && view.state.field(modeState) === 'visual') view.dispatch({ effects: refreshHTMLBlocks.of(null) });
    });
  }
  update(update: ViewUpdate) {
    if (update.docChanged) this.hasHTML = update.state.doc.toString().includes('<');
    if ((update.docChanged || update.selectionSet || update.viewportChanged) && !update.transactions.some(transaction => transaction.effects.some(effect => effect.is(refreshHTMLBlocks)))) this.scheduleHTMLRefresh(update.view);
    // Keep layout and the IME's editable DOM stable until its final input flush.
    // Mapping preserves display offsets without rebuilding provisional markup.
    if (update.state.field(compositionState) && update.state.field(modeState) === 'visual') {
      this.decorations = this.decorations.map(update.changes); return;
    }
    if (update.docChanged || update.selectionSet || update.viewportChanged || update.transactions.some(t => t.effects.length) || syntaxTree(update.startState) !== syntaxTree(update.state)) {
      this.decorations = decorations(update.view);
    }
  }
}, { decorations: value => value.decorations });
