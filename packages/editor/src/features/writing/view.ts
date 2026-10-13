import { Decoration, EditorView, ViewPlugin, type DecorationSet, type ViewUpdate } from '@codemirror/view';
import { syntaxTree } from '@codemirror/language';
import { writingOptions } from './state.ts';
import { compositionState } from '../source-mode/state.ts';
export const writingPresentation = ViewPlugin.fromClass(class {
  decorations: DecorationSet = Decoration.none;
  private view: EditorView;
  private disposed = false;
  private scheduled = false;
  private widgetsScheduled = false;
  constructor(view: EditorView) { this.view = view; this.refresh(); }
  update(update: ViewUpdate) {
    if (update.docChanged || update.selectionSet || update.viewportChanged || update.startState.field(writingOptions) !== update.state.field(writingOptions)) this.refresh();
    if ((update.docChanged || update.selectionSet || update.startState.field(writingOptions).typewriter !== update.state.field(writingOptions).typewriter)
        && update.state.field(writingOptions).typewriter && !update.state.field(compositionState) && !this.scheduled) {
      this.scheduled = true;
      queueMicrotask(() => {
        this.scheduled = false;
        if (!this.disposed && this.view.state.field(writingOptions).typewriter && !this.view.composing
            && !this.view.state.field(compositionState)) this.view.dispatch({ effects: EditorView.scrollIntoView(this.view.state.selection.main.head, { y: 'center' }) });
      });
    }
  }
  private refresh() {
    const state = this.view.state;
    if (!this.widgetsScheduled) {
      this.widgetsScheduled = true;
      queueMicrotask(() => {
        this.widgetsScheduled = false;
        if (this.disposed) return;
        const current = this.view.state;
        for (const table of this.view.dom.querySelectorAll<HTMLElement>('.markdown-table, .ot-preview')) {
          const from = Number(table.dataset.tableFrom ?? table.dataset.previewFrom), to = Number(table.dataset.tableTo ?? table.dataset.previewTo);
          const active = current.selection.ranges.some(range => range.from <= to && range.to >= from);
          table.classList.toggle('ot-unfocused', current.field(writingOptions).focus && !active);
        }
      });
    }
    if (!state.field(writingOptions).focus) { this.decorations = Decoration.none; return; }
    let from = state.selection.main.from, to = state.selection.main.to;
    let node = syntaxTree(state).resolveInner(state.selection.main.head, 1);
    while (node.parent && !/^(Paragraph|ATXHeading\d|SetextHeading\d|FencedCode|CodeBlock|MathBlock|Table|ListItem)$/.test(node.name)) node = node.parent;
    if (node.parent) { from = Math.min(from, node.from); to = Math.max(to, node.to); }
    const marks = [];
    for (const range of this.view.visibleRanges) {
      for (let n = state.doc.lineAt(range.from).number; n <= state.doc.lineAt(range.to).number; n++) {
        const line = state.doc.line(n);
        if (line.to < from || line.from > to) marks.push(Decoration.line({ class: 'ot-unfocused' }).range(line.from));
      }
    }
    this.decorations = Decoration.set(marks, true);
  }
  destroy() { this.disposed = true; }
}, { decorations: value => value.decorations });
