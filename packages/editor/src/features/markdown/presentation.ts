import { syntaxTree } from '@codemirror/language';
import { Decoration, EditorView, ViewPlugin, type DecorationSet, type ViewUpdate } from '@codemirror/view';
import { compositionState, modeState } from '../source-mode/state.ts';

const hiddenMarks = new Set(['HeaderMark', 'EmphasisMark', 'StrikethroughMark', 'CodeMark']);

function decorations(view: EditorView): DecorationSet {
  if (view.state.field(modeState) === 'source' || view.state.field(compositionState)) return Decoration.none;
  const ranges: ReturnType<Decoration['range']>[] = [];
  const tree = syntaxTree(view.state);
  for (const visible of view.visibleRanges) tree.iterate({ from: visible.from, to: visible.to, enter(node) {
    if (node.name === 'Table' || node.name === 'FencedCode') return false;
    if (!hiddenMarks.has(node.name)) return;
    const parent = node.node.parent!;
    const active = view.state.selection.ranges.some(range => range.from <= parent.to && range.to >= parent.from);
    if (active) return;
    ranges.push(Decoration.replace({}).range(node.from, node.to));
  } });
  return Decoration.set(ranges, true);
}

export const markdownPresentation = ViewPlugin.fromClass(class {
  decorations: DecorationSet;
  constructor(view: EditorView) { this.decorations = decorations(view); }
  update(update: ViewUpdate) {
    if (update.docChanged || update.selectionSet || update.viewportChanged || update.transactions.some(t => t.effects.length) || syntaxTree(update.startState) !== syntaxTree(update.state)) {
      this.decorations = decorations(update.view);
    }
  }
}, { decorations: value => value.decorations });
