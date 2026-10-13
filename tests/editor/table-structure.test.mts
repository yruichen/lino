import assert from 'node:assert/strict';
import { test } from 'node:test';
import { EditorState, type TransactionSpec } from '@codemirror/state';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { history, undo, redo } from '@codemirror/commands';
import { sourceDocument } from '../../packages/editor/src/transactions/line-endings.ts';
import { tableCommandTransaction, type TableCommand } from '../../packages/editor/src/features/tables/commands.ts';
import { tableCellFocus, focusTableCell } from '../../packages/editor/src/features/tables/state.ts';
import { tablesIn } from '../../packages/editor/src/features/tables/model.ts';
import { modeState, compositionState, changeComposition, changeMode } from '../../packages/editor/src/features/source-mode/state.ts';

function editor(raw: string, row = 1, column = 0) {
  const source = sourceDocument(raw), table = tablesIn(source.doc.toString())[0];
  const selected = row === 0 ? table.header : table.rows[row - 1];
  let state = EditorState.create({ doc: source.doc, selection: { anchor: selected.cells[column]?.from ?? selected.to },
    extensions: [source.extension, markdown({ base: markdownLanguage }), modeState, compositionState, tableCellFocus, history()] });
  state = state.update({ effects: focusTableCell.of({ tableFrom: table.from, row, column }) }).state;
  return {
    get state() { return state; },
    dispatch(spec: TransactionSpec) { state = state.update(spec).state; },
    command(command: Exclude<TableCommand, 'insert-table'>) { const spec = tableCommandTransaction(state, command); if (spec) this.dispatch(spec); return !!spec; },
    read: () => source.read(state),
    table: () => tablesIn(state.doc.toString())[0],
  };
}
const raw = 'before\r\n\r\n| A | B |\r\n| :--- | ---: |\r\n| x\\|z | y |\r\n| 中 | 👩🏽‍💻 |\r\n\r\nafter';
test('every table structure command is one undoable edit with original surrounding source and focus restored', () => {
  for (const [command, row, column] of [
    ['add-row', 1, 0], ['add-column', 1, 0], ['delete-row', 1, 0], ['delete-column', 1, 1],
    ['move-row-down', 1, 0], ['move-row-up', 2, 0], ['move-column-right', 1, 0], ['move-column-left', 1, 1],
    ['align-column-left', 1, 1], ['align-column-center', 1, 0], ['align-column-right', 1, 0], ['delete-table', 1, 0],
  ] as const) {
    const e = editor(raw, row, column), focus = e.state.field(tableCellFocus);
    assert(e.command(command), command);
    const changed = e.read(); assert.notEqual(changed, raw, command);
    assert(changed.startsWith('before\r\n\r\n') && changed.endsWith('\r\n\r\nafter'), command);
    e.dispatch({ effects: changeMode.of('source') });
    assert(undo(e), command); assert.equal(e.read(), raw, command);
    assert.deepEqual(e.state.field(tableCellFocus), focus, command);
    e.dispatch({ effects: changeMode.of('visual') });
    assert(redo(e), command); assert.equal(e.read(), changed, command);
  }
});
test('moves transport complete row and column values, keep alignment attached to columns and preserve hidden cells', () => {
  const e = editor(raw);
  e.command('move-row-down');
  assert.deepEqual(e.table().rows.map(row => row.cells.map(cell => cell.text)), [['中', '👩🏽‍💻'], ['x\\|z', 'y']]);
  assert.equal(e.state.field(tableCellFocus)!.row, 2);
  e.command('move-column-right');
  assert.deepEqual(e.table().header.cells.map(cell => cell.text), ['B', 'A']);
  assert.deepEqual(e.table().delimiter.cells.map(cell => cell.text), ['---:', ':---']);
  assert.deepEqual(e.table().rows[1].cells.map(cell => cell.text), ['y', 'x\\|z']);
  assert.equal(e.state.field(tableCellFocus)!.column, 1);
  const extra = editor('| A | B |\n| --- | --- |\n| x | y | hidden |');
  extra.command('move-column-right');
  assert.deepEqual(extra.table().rows[0].cells.map(cell => cell.text), ['y', 'x', 'hidden']);
  extra.command('delete-column');
  assert(extra.read().includes('hidden'));
});
test('missing cells stay valid after moving/deleting a column and the final body row can be removed', () => {
  const sparse = editor('| A | B | C |\n| --- | --- | --- |\n| x |', 1, 0);
  sparse.command('move-column-right');
  assert.deepEqual(sparse.table().rows[0].cells.map(cell => cell.text), ['', 'x']);
  const e = editor('| A | B |\n| --- | --- |\n| x |', 1, 0);
  e.command('delete-column');
  assert.equal(e.table().rows.length, 1); assert.equal(e.table().rows[0].cells[0].text, '');
  e.command('delete-row');
  assert.equal(e.table().rows.length, 0); assert.equal(e.state.field(tableCellFocus)!.row, 0);
});
test('boundary failures, header protection, readonly/composition and nested restrictions retain all source', () => {
  for (const [source, row, column, command] of [
    [raw, 0, 0, 'delete-row'], [raw, 1, 0, 'move-row-up'], [raw, 2, 0, 'move-row-down'],
    [raw, 1, 0, 'move-column-left'], [raw, 1, 1, 'move-column-right'],
    ['| A |\n| --- |\n| x |', 1, 0, 'delete-column'],
    ['> | A |\n> | --- |\n> | x |', 1, 0, 'delete-row'],
  ] as const) {
    const e = editor(source, row, column);
    assert.throws(() => e.command(command), command); assert.equal(e.read(), source);
  }
  const e = editor(raw); e.dispatch({ effects: changeComposition.of(true) });
  assert.equal(e.command('delete-table'), false); assert.equal(e.read(), raw);
  const readOnly = EditorState.create({ doc: '| A |\n| --- |\n| x |', selection: { anchor: 17 }, extensions: [markdown({ base: markdownLanguage }), EditorState.readOnly.of(true)] });
  assert.equal(tableCommandTransaction(readOnly, 'delete-table'), undefined);
});
