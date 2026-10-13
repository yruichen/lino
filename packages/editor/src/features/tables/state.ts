import { EditorSelection, StateEffect, StateField, Transaction, type ChangeSpec, type EditorState } from '@codemirror/state';
import { isolateHistory } from '@codemirror/commands';
import type { EditorView } from '@codemirror/view';
import { compositionState } from '../source-mode/state.ts';

export interface TableCellFocus { tableFrom: number; row: number; column: number }
export const focusTableCell = StateEffect.define<TableCellFocus>();
export const tableCellFocus = StateField.define<TableCellFocus | undefined>({
  create: () => undefined,
  update(value, transaction) {
    if (value && transaction.docChanged) value = { ...value, tableFrom: transaction.changes.mapPos(value.tableFrom, 1) };
    if (transaction.selection) value = undefined;
    for (const effect of transaction.effects) if (effect.is(focusTableCell)) value = effect.value;
    return value;
  },
});
export function tableWritable(state: EditorState, composing = false): boolean { return !state.readOnly && !composing && !state.field(compositionState, false); }
export function tableTransaction(view: EditorView, changes: ChangeSpec, focus?: TableCellFocus, anchor?: number): boolean {
  if (!tableWritable(view.state, view.composing)) return false;
  view.dispatch({ changes, ...(anchor === undefined ? {} : { selection: EditorSelection.cursor(anchor) }), effects: focus ? focusTableCell.of(focus) : [],
    annotations: [Transaction.userEvent.of('input.table'), isolateHistory.of('full')] });
  return true;
}
export function restoreCellFocus(view: EditorView, focus: TableCellFocus): void {
  const snapshot = view.state.doc;
  queueMicrotask(() => {
    if (!view.dom.isConnected || view.state.doc !== snapshot) return;
    const current = view.state.field(tableCellFocus, false);
    if (!current || current.tableFrom !== focus.tableFrom || current.row !== focus.row || current.column !== focus.column) return;
    const input = view.dom.querySelector<HTMLInputElement>(`.markdown-table[data-table-from="${focus.tableFrom}"] input[data-row="${focus.row}"][data-column="${focus.column}"]`);
    if (input) { input.focus(); input.select(); }
  });
}
