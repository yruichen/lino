import { ensureSyntaxTree } from '@codemirror/language';
import type { ChangeSpec, EditorState, TransactionSpec } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import { tFor } from '../../localization/index.ts';
import { localeFacet } from '../../localization/editor.ts';
import { appendColumn, appendRow, tableFromNode, type MarkdownTable } from './model.ts';
import { alignColumn, deleteColumn, deleteRow, deleteTable, moveColumn, moveRow } from './structure.ts';
import { TableError, type TableErrorCode } from './errors.ts';
import { showTableInsertion } from './controls.ts';
import { focusContext } from '../../controls/contextual.ts';
import { restoreCellFocus, tableCellFocus, tableTransaction, tableWritable, type TableCellFocus } from './state.ts';

export const tableCommands = ['insert-table', 'add-row', 'add-column', 'delete-row', 'delete-column', 'move-row-up', 'move-row-down', 'move-column-left', 'move-column-right', 'align-column-left', 'align-column-center', 'align-column-right', 'delete-table'] as const;
export type TableCommand = typeof tableCommands[number];
function tableAt(state: EditorState, position: number): MarkdownTable | undefined {
  const tree = ensureSyntaxTree(state, position, 50);
  let table: MarkdownTable | undefined;
  tree?.iterate({ from: position, to: position, enter(node) { if (node.name === 'Table') table = tableFromNode(node.node, (from, to) => state.doc.sliceString(from, to)); } });
  return table;
}
export function currentTable(state: EditorState): { table: MarkdownTable; row: number; column: number } {
  const position = state.selection.main.head, focus = state.field(tableCellFocus, false);
  const table = tableAt(state, position);
  if (!table) throw new TableError('selectCell');
  const found: MarkdownTable = table;
  if (focus?.tableFrom === found.from && focus.row >= 0 && focus.row <= found.rows.length && focus.column >= 0 && focus.column < found.header.cells.length) return { table: found, row: focus.row, column: focus.column };
  const rows = [found.header, ...found.rows];
  const row = rows.findIndex(candidate => position >= candidate.from && position <= candidate.to);
  const target = row < 0 ? found.delimiter : rows[row];
  const column = Math.min(found.header.cells.length - 1, Math.max(0, target.cells.findIndex(cell => position <= cell.rawTo)));
  return { table: found, row: Math.max(0, row), column };
}
export function tableCommandTransaction(state: EditorState, command: Exclude<TableCommand, 'insert-table'>): TransactionSpec | undefined {
    if (!tableWritable(state)) return undefined;
    const { table, row, column } = currentTable(state);
    let changes: ChangeSpec, focus: TableCellFocus = { tableFrom: table.from, row, column };
    switch (command) {
      case 'add-row': changes = appendRow(table); focus.row = table.rows.length + 1; focus.column = 0; break;
      case 'add-column': changes = appendColumn(table, tFor(state.facet(localeFacet), 'table.newColumn')); focus.column = table.header.cells.length; break;
      case 'delete-row': changes = deleteRow(table, row); focus.row = Math.min(row, table.rows.length - 1); break;
      case 'delete-column': changes = deleteColumn(table, column); focus.column = Math.min(column, table.header.cells.length - 2); break;
      case 'move-row-up': changes = moveRow(table, row, -1); focus.row--; break;
      case 'move-row-down': changes = moveRow(table, row, 1); focus.row++; break;
      case 'move-column-left': changes = moveColumn(table, column, -1); focus.column--; break;
      case 'move-column-right': changes = moveColumn(table, column, 1); focus.column++; break;
      case 'align-column-left': changes = alignColumn(table, column, 'left'); break;
      case 'align-column-center': changes = alignColumn(table, column, 'center'); break;
      case 'align-column-right': changes = alignColumn(table, column, 'right'); break;
      case 'delete-table': changes = deleteTable(table); break;
    }
    const transaction = state.update({ changes });
    if (command === 'delete-table') return tableTransaction(changes, undefined, Math.min(table.from, transaction.newDoc.length));
    // Project focus from the final document. This does not create another model.
    const updated = tableAt(transaction.state, table.from);
    if (!updated) throw new TableError('invalidStructure');
    const selected = focus.row === 0 ? updated.header : updated.rows[focus.row - 1];
    const anchor = selected.cells[focus.column]?.from ?? selected.to;
    return tableTransaction(changes, focus, anchor);
}
export function runTableCommand(view: EditorView, command: TableCommand, reportError: (message: string, code?: TableErrorCode) => void): boolean {
  if (!tableWritable(view.state, view.composing)) return false;
  if (command === 'insert-table') { view.dispatch({ effects: [focusContext.of('table'), showTableInsertion.of(true)] }); return true; }
  const locale = view.state.facet(localeFacet);
  try {
    const transaction = tableCommandTransaction(view.state, command);
    if (!transaction) return false;
    view.dispatch(transaction);
    const focus = view.state.field(tableCellFocus);
    if (focus) restoreCellFocus(view, focus);
    return true;
  } catch (error) { reportError(error instanceof TableError ? tFor(locale, `table.${error.code}`) : String(error), error instanceof TableError ? error.code : undefined); return false; }
}
export { tableControls } from './controls.ts';
