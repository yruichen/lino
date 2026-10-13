import assert from 'node:assert/strict';
import { test } from 'node:test';
import { EditorState, Transaction, type TransactionSpec } from '@codemirror/state';
import { history, undo, redo, isolateHistory } from '@codemirror/commands';
import { sourceDocument } from '../../packages/editor/src/transactions/line-endings.ts';
import { appendColumn, appendRow, editCell, tablesIn } from '../../packages/editor/src/features/tables/model.ts';
import { changeMode, modeState } from '../../packages/editor/src/features/source-mode/state.ts';

function document(raw: string) {
  const source = sourceDocument(raw);
  let state = EditorState.create({ doc: source.doc, extensions: [source.extension, modeState, history()] });
  return {
    get state() { return state; },
    dispatch(transaction: Transaction | TransactionSpec) { state = transaction instanceof Transaction ? transaction.state : state.update(transaction).state; },
    read: () => source.read(state),
  };
}

test('unchanged source preserves mixed endings, Unicode and final newline', () => {
  for (const raw of ['', '\r', '\r\n', '\n', '汉字👩🏽‍💻\r\n第二行\n第三行\r尾行', 'a\r\nb\n']) {
    const editor = document(raw);
    assert.equal(editor.read(), raw);
    editor.dispatch({ effects: changeMode.of('source') });
    editor.dispatch({ effects: changeMode.of('visual') });
    assert.equal(editor.read(), raw);
  }
});

test('source metadata follows changes and undo restores deleted original line endings', () => {
  const raw = '甲\r\n乙\n丙\r丁';
  const editor = document(raw);
  editor.dispatch({ changes: { from: 1, to: 4, insert: '新\n' }, annotations: isolateHistory.of('full') });
  assert.equal(editor.read(), '甲新\r\n丙\r丁');
  assert.equal(undo(editor), true);
  assert.equal(editor.read(), raw);
  assert.equal(redo(editor), true);
  assert.equal(editor.read(), '甲新\r\n丙\r丁');
});

test('table edits preserve untouched Markdown, escaped pipes and Unicode', () => {
  const raw = '前言\n\n| A | B |\n| :--- | ---: |\n| 中\\|文 | 👩🏽‍💻 |\n\n尾言';
  const editor = document(raw);
  const table = tablesIn(editor.state.doc.toString())[0];
  editor.dispatch({ changes: editCell(table, 1, 1, '新|值'), annotations: isolateHistory.of('full') });
  assert.equal(editor.read(), raw.replace('👩🏽‍💻', '新\\|值'));
  assert(undo(editor)); assert.equal(editor.read(), raw);
});

test('grouped typing and subsequent history entries keep source metadata aligned', () => {
  const raw = 'a\r\nb\nc\r';
  const editor = document(raw);
  editor.dispatch({ changes: { from: 0, insert: 'x\n' }, annotations: Transaction.userEvent.of('input.type') });
  editor.dispatch({ changes: { from: 2, insert: 'y' }, annotations: Transaction.userEvent.of('input.type') });
  assert(undo(editor)); assert.equal(editor.read(), raw);
  assert(redo(editor)); assert.equal(editor.read(), 'x\r\nya\r\nb\nc\r');
  editor.dispatch({ changes: { from: editor.state.doc.length, insert: 'z' }, annotations: isolateHistory.of('full') });
  assert(undo(editor)); assert.equal(editor.read(), 'x\r\nya\r\nb\nc\r');
  assert(undo(editor)); assert.equal(editor.read(), raw);
});

test('tables in fences are not interpreted as editable tables', () => {
  assert.equal(tablesIn('```md\n| A | B |\n| --- | --- |\n| x | y |\n```').length, 0);
});

test('missing GFM cells are filled without dropping existing or extra cells', () => {
  const editor = document('| A | B | C |\n| --- | --- | --- |\n| 中 |');
  const table = tablesIn(editor.state.doc.toString())[0];
  editor.dispatch({ changes: editCell(table, 1, 2, '三') });
  assert.deepEqual(tablesIn(editor.state.doc.toString())[0].rows[0].cells.map(c => c.text), ['中', '', '三']);
  const extra = document('| A | B |\n| --- | --- |\n| x | y | 不应丢失 |');
  extra.dispatch({ changes: editCell(tablesIn(extra.state.doc.toString())[0], 1, 0, '新') });
  assert(extra.read().includes('| 新 | y | 不应丢失 |'));
  extra.dispatch({ changes: appendColumn(tablesIn(extra.state.doc.toString())[0]) });
  assert.deepEqual(tablesIn(extra.state.doc.toString())[0].rows[0].cells.map(c => c.text), ['新', 'y', '', '不应丢失']);
});

test('row and column changes are atomic and survive mode switches in one history', () => {
  const raw = '| A | B |\r\n| --- | --- |\r\n| x | y |\r\n';
  const editor = document(raw);
  editor.dispatch({ changes: appendRow(tablesIn(editor.state.doc.toString())[0]), annotations: isolateHistory.of('full') });
  assert.equal(tablesIn(editor.state.doc.toString())[0].rows.length, 2);
  editor.dispatch({ effects: changeMode.of('source') });
  assert(undo(editor)); assert.equal(editor.read(), raw);
  assert(redo(editor)); assert.equal(tablesIn(editor.state.doc.toString())[0].rows.length, 2);
  assert(undo(editor));
  editor.dispatch({ changes: appendColumn(tablesIn(editor.state.doc.toString())[0]), annotations: isolateHistory.of('full') });
  assert.equal(tablesIn(editor.state.doc.toString())[0].header.cells.length, 3);
  assert.equal(tablesIn(editor.state.doc.toString())[0].rows[0].cells.length, 3);
  assert(undo(editor)); assert.equal(editor.read(), raw);
});

test('invalid cell edits do not silently rewrite structure', () => {
  const table = tablesIn('| A |\n| --- |\n| x |')[0];
  assert.throws(() => editCell(table, 1, 0, 'x\ny'));
  assert.throws(() => editCell(table, 7, 0, 'x'));
  assert.throws(() => editCell(table, 1, 2, 'x'));
});

test('quoted and list-nested tables retain their container during structure changes', () => {
  for (const raw of ['> | A | B |\n> | --- | --- |\n> | x | y |', '- item\n\n  | A | B |\n  | --- | --- |\n  | x | y |']) {
    const editor = document(raw);
    const table = tablesIn(editor.state.doc.toString())[0];
    assert.equal(table.rows.length, 1);
    editor.dispatch({ changes: appendRow(table), annotations: isolateHistory.of('full') });
    assert.equal(tablesIn(editor.state.doc.toString())[0].rows.length, 2);
    assert(undo(editor)); assert.equal(editor.read(), raw);
    editor.dispatch({ changes: appendColumn(tablesIn(editor.state.doc.toString())[0]), annotations: isolateHistory.of('full') });
    assert.equal(tablesIn(editor.state.doc.toString())[0].header.cells.length, 3);
    assert(undo(editor)); assert.equal(editor.read(), raw);
  }
});

test('deleting a newline at the range start does not duplicate a surviving newline', () => {
  const raw = 'a\r\nremove\nlast', editor = document(raw);
  editor.dispatch({ changes: { from: 1, to: 8 }, annotations: isolateHistory.of('full') });
  assert.equal(editor.state.doc.toString(), 'a\nlast');
  assert.equal(editor.read(), 'a\nlast');
  assert(undo(editor)); assert.equal(editor.read(), raw);
  assert(redo(editor)); assert.equal(editor.read(), 'a\nlast');
});
