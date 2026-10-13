import assert from 'node:assert/strict';
import { test } from 'node:test';
import { EditorState } from '@codemirror/state';
import { linePosition } from '../../packages/editor/src/features/navigation/line.ts';

test('source line navigation uses one-based lines and never splits Unicode', () => {
  const state = EditorState.create({ doc: '中文👩🏽‍💻\nالعربية\n\n尾行' });
  assert.equal(linePosition(state, '1'), 0);
  assert.equal(linePosition(state, ' 2 '), state.doc.line(2).from);
  assert.equal(linePosition(state, '3'), state.doc.line(3).from);
  assert.equal(linePosition(state, '4'), state.doc.line(4).from);
  for (const value of ['', '0', '-1', '2.5', '2:3', '+1', '1e2', '5', 'Infinity', '999999999999999999999999']) {
    assert.equal(linePosition(state, value), null, value);
  }
});

test('source line lookup validates against the current document', () => {
  const previous = EditorState.create({ doc: 'first\nsecond\nthird' });
  assert.equal(linePosition(previous, '3'), 13);
  const current = previous.update({ changes: { from: 5, to: previous.doc.length } }).state;
  assert.equal(linePosition(current, '3'), null);
  assert.equal(linePosition(current, '1'), 0);
  assert.equal(linePosition(EditorState.create(), '1'), 0);
});
