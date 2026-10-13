import type { ChangeSpec } from '@codemirror/state';
import { hasTrailingPipe, parseRow, type MarkdownTable, type TableRow } from './model.ts';
import { TableError } from './errors.ts';

export type ColumnAlignment = 'left' | 'center' | 'right';
function topLevel(table: MarkdownTable): void { if (table.rowPrefix) throw new TableError('nested'); }
function validColumn(table: MarkdownTable, column: number): void {
  if (!Number.isInteger(column) || column < 0 || column >= table.header.cells.length) throw new TableError('invalidCell');
}
function bodyRow(table: MarkdownTable, row: number): TableRow {
  if (row === 0) throw new TableError('headerRow');
  if (!Number.isInteger(row) || row < 1 || row > table.rows.length) throw new TableError('invalidCell');
  return table.rows[row - 1];
}
export function deleteRow(table: MarkdownTable, row: number): ChangeSpec {
  topLevel(table);
  const current = bodyRow(table, row), previous = row === 1 ? table.delimiter : table.rows[row - 2];
  const next = table.rows[row];
  return next ? { from: current.from, to: next.from } : { from: previous.to, to: current.to };
}
export function moveRow(table: MarkdownTable, row: number, direction: -1 | 1): ChangeSpec[] {
  topLevel(table);
  const current = bodyRow(table, row), nextIndex = row + direction;
  if (nextIndex < 1 || nextIndex > table.rows.length) throw new TableError('rowBoundary');
  const other = bodyRow(table, nextIndex);
  return [{ from: current.from, to: current.to, insert: other.source }, { from: other.from, to: other.to, insert: current.source }].sort((left, right) => left.from - right.from);
}
export function deleteColumn(table: MarkdownTable, column: number): ChangeSpec[] {
  validColumn(table, column);
  if (table.header.cells.length === 1) throw new TableError('lastColumn');
  return [table.header, table.delimiter, ...table.rows].flatMap(row => {
    const cell = row.cells[column];
    if (!cell) return [];
    // A one-cell body row still represents a row after its visible value is
    // removed. Materialize an empty cell instead of producing a blank line.
    if (row.cells.length === 1) return [{ from: row.from, to: row.to, insert: '| |' }];
    const next = row.cells[column + 1], previous = row.cells[column - 1];
    return [next ? { from: cell.rawFrom, to: next.rawFrom } : { from: previous.rawTo, to: cell.rawTo }];
  });
}
function filledRow(row: TableRow, columns: number): TableRow {
  if (row.cells.length >= columns) return row;
  const end = row.source.trimEnd().length;
  const suffix = (hasTrailingPipe(row.source) ? '' : ' |') + '  |'.repeat(columns - row.cells.length);
  return parseRow(row.source.slice(0, end) + suffix + row.source.slice(end), row.from);
}
export function moveColumn(table: MarkdownTable, column: number, direction: -1 | 1): ChangeSpec[] {
  validColumn(table, column);
  const other = column + direction;
  if (other < 0 || other >= table.header.cells.length) throw new TableError('columnBoundary');
  return [table.header, table.delimiter, ...table.rows].flatMap(original => {
    if (original.cells.length <= Math.min(column, other)) return [];
    const row = filledRow(original, Math.max(column, other) + 1);
    const left = row.cells[Math.min(column, other)], right = row.cells[Math.max(column, other)];
    const leftText = row.source.slice(left.rawFrom - row.from, left.rawTo - row.from);
    const rightText = row.source.slice(right.rawFrom - row.from, right.rawTo - row.from);
    if (row === original) return [{ from: left.rawFrom, to: left.rawTo, insert: rightText }, { from: right.rawFrom, to: right.rawTo, insert: leftText }];
    const source = row.source.slice(0, left.rawFrom - row.from) + rightText + row.source.slice(left.rawTo - row.from, right.rawFrom - row.from) + leftText + row.source.slice(right.rawTo - row.from);
    return [{ from: original.from, to: original.to, insert: source }];
  });
}
export function alignColumn(table: MarkdownTable, column: number, alignment: ColumnAlignment): ChangeSpec {
  validColumn(table, column);
  const cell = table.delimiter.cells[column];
  if (!cell) throw new TableError('invalidStructure');
  const dashes = '-'.repeat(Math.max(3, cell.text.replace(/:/g, '').length));
  return { from: cell.from, to: cell.to, insert: (alignment === 'right' ? '' : ':') + dashes + (alignment === 'left' ? '' : ':') };
}
export function deleteTable(table: MarkdownTable): ChangeSpec { topLevel(table); return { from: table.from, to: table.to }; }
