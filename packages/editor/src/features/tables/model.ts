import { markdownLanguage } from '@codemirror/lang-markdown';
import type { ChangeSpec } from '@codemirror/state';
import { TableError } from './errors.ts';

type SyntaxNode = ReturnType<typeof markdownLanguage.parser.parse>['topNode'];
type ReadSource = (from: number, to: number) => string;
export interface TableCell { from: number; to: number; text: string; rawFrom: number; rawTo: number }
export interface TableRow { from: number; to: number; source: string; cells: TableCell[] }
export interface MarkdownTable {
  from: number; to: number; source: string;
  header: TableRow; delimiter: TableRow; rows: TableRow[];
  rowPrefix: string;
}

export function parseRow(source: string, from: number): TableRow {
  const pipes: number[] = [], cells: TableCell[] = [];
  let escapes = 0;
  for (let index = 0; index < source.length; index++) {
    const character = source[index];
    if (character === '|' && escapes % 2 === 0) pipes.push(from + index);
    escapes = character === '\\' ? escapes + 1 : 0;
  }
  const to = from + source.length, boundaries = [from - 1, ...pipes, to];
  for (let index = 0; index < boundaries.length - 1; index++) {
    const rawFrom = boundaries[index] + 1, rawTo = boundaries[index + 1];
    const raw = source.slice(rawFrom - from, rawTo - from);
    if ((index === 0 && pipes.length && !raw.trim()) || (index === boundaries.length - 2 && pipes.length && !raw.trim())) continue;
    const start = Math.min(rawTo, rawFrom + raw.length - raw.trimStart().length);
    const end = Math.max(start, rawTo - (raw.length - raw.trimEnd().length));
    cells.push({ from: start, to: end, text: source.slice(start - from, end - from), rawFrom, rawTo });
  }
  return { from, to, source, cells };
}
function row(node: SyntaxNode, source: ReadSource): TableRow { return parseRow(source(node.from, node.to), node.from); }

export function tableFromNode(node: SyntaxNode, source: ReadSource): MarkdownTable {
  let header: SyntaxNode | undefined, delimiter: SyntaxNode | undefined;
  const rows: TableRow[] = [];
  for (let child = node.firstChild; child; child = child.nextSibling) {
    if (child.name === 'TableHeader') header = child;
    else if (child.name === 'TableDelimiter') delimiter = child;
    else if (child.name === 'TableRow') rows.push(row(child, source));
  }
  if (!header || !delimiter) throw new TableError('invalidStructure');
  const text = source(node.from, node.to);
  const finalRow = rows.at(-1) ?? row(delimiter, source);
  const offset = finalRow.from - node.from;
  const rowPrefix = text.slice(text.lastIndexOf('\n', offset - 1) + 1, offset);
  return { from: node.from, to: node.to, source: text, header: row(header, source), delimiter: row(delimiter, source), rows, rowPrefix };
}

export function tablesIn(source: string): MarkdownTable[] {
  const tables: MarkdownTable[] = [];
  const tree = markdownLanguage.parser.parse(source);
  tree.iterate({ enter(node) {
    if (node.name !== 'Table') return;
    tables.push(tableFromNode(node.node, (from, to) => source.slice(from, to)));
    return false;
  } });
  return tables;
}

export function hasTrailingPipe(source: string): boolean {
  const text = source.trimEnd();
  if (!text.endsWith('|')) return false;
  let escapes = 0;
  for (let i = text.length - 2; i >= 0 && text[i] === '\\'; i--) escapes++;
  return escapes % 2 === 0;
}

function escapePipes(value: string): string {
  if (/[\r\n]/.test(value)) throw new TableError('singleLine');
  let result = '', escapes = 0;
  for (const character of value) {
    if (character === '|' && escapes % 2 === 0) result += '\\';
    result += character;
    escapes = character === '\\' ? escapes + 1 : 0;
  }
  return result;
}

export function editCell(table: MarkdownTable, rowIndex: number, column: number, value: string): ChangeSpec {
  const target = rowIndex === 0 ? table.header : table.rows[rowIndex - 1];
  if (!target || !Number.isInteger(rowIndex) || !Number.isInteger(column) || column < 0 || column >= table.header.cells.length) throw new TableError('invalidCell');
  const text = escapePipes(value);
  const cell = target.cells[column];
  if (cell) return { from: cell.from, to: cell.to, insert: text };
  // GFM permits missing body cells. Materialize only the requested suffix,
  // without rebuilding existing cells or discarding extra source columns.
  const end = target.source.trimEnd().length;
  const insert = (hasTrailingPipe(target.source) ? '' : ' |') + '  |'.repeat(column - target.cells.length) + ` ${text} |`;
  return { from: target.from + end, insert };
}

export function appendRow(table: MarkdownTable): ChangeSpec {
  validateDimensions(table.rows.length + 1, table.header.cells.length);
  return { from: table.to, insert: `\n${table.rowPrefix}| ${table.header.cells.map(() => ' ').join(' | ')} |` };
}

export function appendColumn(table: MarkdownTable, label = ''): ChangeSpec[] {
  validateDimensions(table.rows.length, table.header.cells.length + 1, true);
  return [table.header, table.delimiter, ...table.rows].map((target, index) => {
    if (index >= 2 && target.cells.length > table.header.cells.length) {
      // Extra source cells are ignored by GFM. Insert before them so adding
      // a header does not accidentally promote previously hidden content.
      return { from: target.cells[table.header.cells.length].from, insert: '  | ' };
    }
    const end = target.source.trimEnd().length;
    // Fill implicit missing cells before the new column.
    const missing = index === 1 ? 0 : Math.max(0, table.header.cells.length - target.cells.length);
    const prefix = hasTrailingPipe(target.source) ? '' : ' |';
    return { from: target.from + end, insert: `${prefix}${'  |'.repeat(missing)} ${index === 0 ? escapePipes(label) : index === 1 ? '---' : ' '} |` };
  });
}

export function validateDimensions(rows: number, columns: number, allowEmptyBody = false): void {
  if (!Number.isInteger(rows) || !Number.isInteger(columns) || rows < (allowEmptyBody ? 0 : 1) || rows > 1000 || columns < 1 || columns > 100 || (rows + 1) * columns > 10000) throw new TableError('limit');
}
export function tableSource(rows: number, columns: number, label: string): string {
  validateDimensions(rows, columns);
  const header = '| ' + Array.from({ length: columns }, (_, index) => escapePipes(label) + ' ' + (index + 1)).join(' | ') + ' |';
  const delimiter = '| ' + Array(columns).fill('---').join(' | ') + ' |';
  const body = '| ' + Array(columns).fill(' ').join(' | ') + ' |';
  return [header, delimiter, ...Array(rows).fill(body)].join('\n');
}
