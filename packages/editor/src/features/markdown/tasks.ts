import { syntaxTree } from '@codemirror/language';
import { isolateHistory } from '@codemirror/commands';
import { Decoration, ViewPlugin, WidgetType, type EditorView, type ViewUpdate, type DecorationSet } from '@codemirror/view';
import { compositionState, modeState } from '../source-mode/state.ts';
import { localeFacet } from '../../localization/editor.ts';
import { tFor, t } from '../../localization/index.ts';
import { selectedLines } from './selection.ts';
import { presentationSelection } from '../../controls/pointer.ts';

export function toggleTasks(view: EditorView): boolean {
  if (view.state.readOnly || view.composing || view.state.field(compositionState)) return false;
  const lines = selectedLines(view.state), changes: { from: number; to: number; insert: string }[] = [];
  syntaxTree(view.state).iterate({ from: lines[0].from, to: lines.at(-1)!.to, enter(node) {
    if (node.name === 'TaskMarker') changes.push({ from: node.from + 1, to: node.to - 1, insert: view.state.sliceDoc(node.from + 1, node.to - 1).toLowerCase() === 'x' ? ' ' : 'x' });
  } });
  if (!changes.length) throw new Error(t('format.selectTask'));
  view.dispatch({ changes, annotations: isolateHistory.of('full'), userEvent: 'input.task' }); view.focus(); return true;
}
class TaskWidget extends WidgetType {
  readonly from: number; readonly raw: string; readonly readonly: boolean; readonly label: string;
  constructor(from: number, raw: string, readonly: boolean, label: string) { super(); this.from = from; this.raw = raw; this.readonly = readonly; this.label = label; }
  override eq(other: TaskWidget): boolean { return this.from === other.from && this.raw === other.raw && this.readonly === other.readonly && this.label === other.label; }
  toDOM(view: EditorView): HTMLElement {
    const input = document.createElement('input'); input.type = 'checkbox'; input.className = 'ot-task-checkbox'; input.checked = this.raw.toLowerCase() === '[x]'; input.disabled = this.readonly;
    input.setAttribute('aria-label', this.label);
    input.addEventListener('change', () => {
      if (view.state.readOnly || view.composing || view.state.field(compositionState) || view.state.sliceDoc(this.from, this.from + 3) !== this.raw) return;
      view.dispatch({ changes: { from: this.from + 1, to: this.from + 2, insert: input.checked ? 'x' : ' ' }, annotations: isolateHistory.of('full'), userEvent: 'input.task' }); view.focus();
    }); return input;
  }
  override ignoreEvent(): boolean { return true; }
}
function build(view: EditorView): DecorationSet {
  if (view.state.field(modeState) === 'source' || view.state.field(compositionState)) return Decoration.none;
  const ranges: ReturnType<Decoration['range']>[] = [];
  for (const visible of view.visibleRanges) syntaxTree(view.state).iterate({ from: visible.from, to: visible.to, enter(node) {
    if (node.name !== 'TaskMarker' || presentationSelection(view.state).ranges.some(range => range.from <= node.to && range.to >= node.from)) return;
    ranges.push(Decoration.replace({ widget: new TaskWidget(node.from, view.state.sliceDoc(node.from, node.to), view.state.readOnly, tFor(view.state.facet(localeFacet), 'format.toggleTask')) }).range(node.from, node.to));
  } }); return Decoration.set(ranges, true);
}
export const taskPresentation = ViewPlugin.fromClass(class {
  decorations: DecorationSet;
  constructor(view: EditorView) { this.decorations = build(view); }
  update(update: ViewUpdate) {
    if (update.docChanged || update.selectionSet || update.viewportChanged || update.transactions.some(tr => tr.effects.length) || syntaxTree(update.startState) !== syntaxTree(update.state)) this.decorations = build(update.view);
  }
}, { decorations: value => value.decorations });
