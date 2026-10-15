import { syntaxTree } from '@codemirror/language';
import { Decoration, EditorView, ViewPlugin, WidgetType, type DecorationSet, type ViewUpdate } from '@codemirror/view';
import { compositionState, modeState } from '../source-mode/state.ts';
import { presentationSelection } from '../../controls/pointer.ts';

const hiddenMarks = new Set(['HeaderMark', 'QuoteMark', 'EmphasisMark', 'StrikethroughMark', 'CodeMark', 'HighlightMark', 'ScriptMark']);
const inlineStyles: Readonly<Record<string, string>> = { Highlight: 'ot-highlight', Superscript: 'ot-superscript', Subscript: 'ot-subscript', FrontMatter: 'ot-frontmatter', FootnoteDefinition: 'ot-footnote-definition' };

class RuleWidget extends WidgetType {
  override toDOM(): HTMLElement { const rule = document.createElement('hr'); rule.className = 'ot-horizontal-rule'; return rule; }
  override ignoreEvent(): boolean { return false; }
}
class BulletWidget extends WidgetType {
  override toDOM(): HTMLElement { const bullet = document.createElement('span'); bullet.className = 'ot-list-bullet'; bullet.textContent = '•'; bullet.setAttribute('aria-hidden', 'true'); return bullet; }
  override ignoreEvent(): boolean { return false; }
}
function decorations(view: EditorView): DecorationSet {
  if (view.state.field(modeState) === 'source') return Decoration.none;
  const ranges: ReturnType<Decoration['range']>[] = [];
  const tree = syntaxTree(view.state), lines = new Map<number, Set<string>>();
  const active = (from: number, to: number) => presentationSelection(view.state).ranges.some(range => range.from <= to && range.to >= from);
  const styleLine = (from: number, name: string) => {
    const at = view.state.doc.lineAt(from).from, classes = lines.get(at) ?? new Set<string>(); classes.add(name); lines.set(at, classes);
  };
  for (const visible of view.visibleRanges) tree.iterate({ from: visible.from, to: visible.to, enter(node) {
    if (['Table', 'FencedCode', 'CodeBlock', 'MathBlock', 'InlineMath', 'Image'].includes(node.name)) return false;
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
  constructor(view: EditorView) { this.decorations = decorations(view); }
  update(update: ViewUpdate) {
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
