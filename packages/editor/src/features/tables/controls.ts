import { EditorSelection, StateEffect, StateField, type EditorState, type TransactionSpec } from '@codemirror/state';
import { ensureSyntaxTree } from '@codemirror/language';
import { isolateHistory } from '@codemirror/commands';
import { changeComposition } from '../source-mode/state.ts';
import { showPanel, type EditorView, type Panel, type ViewUpdate } from '@codemirror/view';
import { tFor } from '../../localization/index.ts';
import { localeFacet } from '../../localization/editor.ts';
import { tableSource } from './model.ts';
import { TableError } from './errors.ts';
import { focusTableCell, restoreCellFocus, tableCellFocus, tableWritable } from './state.ts';

export const showTableInsertion = StateEffect.define<boolean>();
interface InsertionDraft { rows: string; columns: string; error: unknown }
const changeInsertionDraft = StateEffect.define<InsertionDraft>();
export function insertionTransaction(state: EditorState, rows: number, columns: number, label: string): TransactionSpec {
  if (!tableWritable(state) || state.selection.ranges.length !== 1) throw new TableError('insertContext');
  const at = state.selection.main.to;
  const tree = ensureSyntaxTree(state, at, 50);
  if (!tree) throw new TableError('insertContext');
  tree.iterate({ from: at, to: at, enter(node) {
    if (['Table', 'FencedCode', 'CodeBlock', 'HTMLBlock', 'ListItem', 'Blockquote'].includes(node.name)) throw new TableError('insertContext');
  } });
  const before = state.doc.sliceString(Math.max(0, at - 2), at), after = state.doc.sliceString(at, Math.min(state.doc.length, at + 2));
  const prefix = !at || before.endsWith('\n\n') ? '' : before.endsWith('\n') ? '\n' : '\n\n';
  const suffix = at === state.doc.length || after.startsWith('\n\n') ? '' : after.startsWith('\n') ? '\n' : '\n\n';
  const text = tableSource(rows, columns, label), tableFrom = at + prefix.length;
  return { changes: { from: at, insert: prefix + text + suffix }, selection: EditorSelection.cursor(tableFrom + 2),
    effects: [showTableInsertion.of(false), focusTableCell.of({ tableFrom, row: 0, column: 0 })],
    annotations: isolateHistory.of('full'), userEvent: 'input.table', scrollIntoView: true };
}
class TableInsertionPanel implements Panel {
  readonly dom = document.createElement('form');
  readonly top = true;
  private readonly view: EditorView;
  private readonly rows = document.createElement('input');
  private readonly columns = document.createElement('input');
  private readonly status = document.createElement('output');
  private readonly submit = document.createElement('button');
  private readonly cancel = document.createElement('button');
  private readonly rowsLabel = document.createElement('label');
  private readonly columnsLabel = document.createElement('label');
  private composing = false;
  constructor(view: EditorView) {
    this.view = view; this.dom.className = 'ot-table-insert'; this.dom.noValidate = true;
    this.rows.type = this.columns.type = 'number'; this.rows.min = this.columns.min = '1'; this.rows.max = '1000'; this.columns.max = '100';
    this.rows.name = 'table-rows'; this.columns.name = 'table-columns';
    this.rowsLabel.append(this.rows); this.columnsLabel.append(this.columns);
    this.submit.type = 'submit'; this.cancel.type = 'button';
    this.status.setAttribute('role', 'status');
    this.dom.append(this.rowsLabel, this.columnsLabel, this.submit, this.cancel, this.status);
    this.dom.addEventListener('input', () => view.dispatch({ effects: changeInsertionDraft.of({
      rows: this.rows.value, columns: this.columns.value, error: undefined,
    }) }));
    this.dom.addEventListener('compositionstart', () => { this.composing = true; view.dispatch({ effects: changeComposition.of(true) }); });
    this.dom.addEventListener('compositionend', () => { this.composing = false; view.dispatch({ effects: changeComposition.of(false) }); });
    this.dom.addEventListener('submit', event => {
      event.preventDefault();
      if (this.composing || !tableWritable(view.state, view.composing)) return;
      try {
        const transaction = insertionTransaction(view.state, this.rows.valueAsNumber, this.columns.valueAsNumber, tFor(view.state.facet(localeFacet), 'table.newColumn'));
        view.dispatch(transaction);
        const focus = view.state.field(tableCellFocus); if (focus) restoreCellFocus(view, focus);
      } catch (error) {
        view.dispatch({ effects: changeInsertionDraft.of({ rows: this.rows.value, columns: this.columns.value, error }) });
      }
    });
    this.cancel.addEventListener('click', () => this.close());
    this.dom.addEventListener('keydown', event => { if (event.key === 'Escape' && !event.isComposing) { event.preventDefault(); this.close(); } });
    this.render();
  }
  private close(): void { if (this.composing) return; this.view.dispatch({ effects: showTableInsertion.of(false) }); this.view.focus(); }
  private render(): void {
    const draft = this.view.state.field(insertionPanel);
    if (this.rows.value !== draft.rows) this.rows.value = draft.rows;
    if (this.columns.value !== draft.columns) this.columns.value = draft.columns;
    const locale = this.view.state.facet(localeFacet), text = (key: 'table.rows' | 'table.columns' | 'table.insert' | 'table.cancel') => tFor(locale, key);
    this.rowsLabel.setAttribute('aria-label', text('table.rows')); this.columnsLabel.setAttribute('aria-label', text('table.columns'));
    this.rowsLabel.dataset.label = text('table.rows'); this.columnsLabel.dataset.label = text('table.columns');
    this.rows.setAttribute('aria-label', text('table.rows')); this.columns.setAttribute('aria-label', text('table.columns'));
    this.submit.textContent = text('table.insert'); this.cancel.textContent = text('table.cancel');
    this.rows.disabled = this.columns.disabled = this.view.state.readOnly;
    this.submit.disabled = !tableWritable(this.view.state, this.view.composing);
    this.status.textContent = draft.error ? draft.error instanceof TableError ? tFor(locale, `table.${draft.error.code}`) : String(draft.error) : '';
  }
  mount(): void { this.rows.focus(); this.rows.select(); }
  update(_update: ViewUpdate): void { this.render(); }
}
const createTableInsertionPanel = (view: EditorView): Panel => new TableInsertionPanel(view);
const insertionPanel = StateField.define<InsertionDraft & { visible: boolean }>({
  create: () => ({ visible: false, rows: '3', columns: '3', error: undefined }),
  update: (draft, transaction) => {
    for (const effect of transaction.effects) {
      if (effect.is(showTableInsertion) && effect.value !== draft.visible) {
        draft = { visible: effect.value, rows: '3', columns: '3', error: undefined };
      } else if (effect.is(changeInsertionDraft)) draft = { ...draft, ...effect.value };
    }
    return draft;
  },
  provide: field => showPanel.from(field, draft => draft.visible ? createTableInsertionPanel : null),
});
export const tableControls = [tableCellFocus, insertionPanel];
