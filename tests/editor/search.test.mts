import assert from 'node:assert/strict';
import { test } from 'node:test';
import { EditorSelection, EditorState, Transaction, type TransactionSpec } from '@codemirror/state';
import { history, redo, undo } from '@codemirror/commands';
import { SearchQuery, replaceAll, search, setSearchQuery } from '@codemirror/search';
import type { EditorView } from '@codemirror/view';
import { sourceDocument } from '../../packages/editor/src/transactions/line-endings.ts';
import { changeComposition, compositionState } from '../../packages/editor/src/features/source-mode/state.ts';
import { MATCH_LIMIT, replacementTransactions, replaceMatches, searchMatches } from '../../packages/editor/src/features/search/commands.ts';

function fixture(raw: string, readOnly = false) {
  const source = sourceDocument(raw);
  let state = EditorState.create({ doc: source.doc, extensions: [source.extension, history(), search(), compositionState, replacementTransactions, EditorState.readOnly.of(readOnly)] });
  const target = {
    get state() { return state; }, composing: false,
    dispatch(transaction: Transaction | TransactionSpec) { state = transaction instanceof Transaction ? transaction.state : state.update(transaction).state; },
  };
  // CM's replacement commands need state + dispatch only; actual DOM, focus,
  // result navigation and search panel are covered by verifySearch in WKWebView.
  return { target: target as unknown as EditorView, read: () => source.read(state),
    query: (config: ConstructorParameters<typeof SearchQuery>[0]) => target.dispatch({ effects: setSearchQuery.of(new SearchQuery(config)) }),
  };
}

test('search uses case, whole-word, Unicode and escaped newline semantics', () => {
  const editor = fixture('cat Cat scatter 中文🙂\r\ncat');
  editor.query({ search: 'cat' }); assert.equal(searchMatches(editor.target.state).ranges.length, 4);
  editor.query({ search: 'cat', caseSensitive: true, wholeWord: true }); assert.equal(searchMatches(editor.target.state).ranges.length, 2);
  editor.query({ search: '中文🙂\\ncat' }); assert.equal(searchMatches(editor.target.state).ranges.length, 1);
  assert.equal(editor.read(), 'cat Cat scatter 中文🙂\r\ncat');
});

test('replace all is one undoable transaction and preserves untouched mixed endings', () => {
  const raw = '猫🙂\r\n猫\n尾\r猫', editor = fixture(raw);
  editor.query({ search: '猫', replace: '新👩🏽‍💻' });
  assert(replaceMatches(editor.target, true));
  const changed = '新👩🏽‍💻🙂\r\n新👩🏽‍💻\n尾\r新👩🏽‍💻';
  assert.equal(editor.read(), changed);
  assert(undo(editor.target)); assert.equal(editor.read(), raw);
  assert(redo(editor.target)); assert.equal(editor.read(), changed);
});

test('regex capture replacements and newline edits preserve source on undo', () => {
  const raw = 'item12\r\nitem34\n结束', editor = fixture(raw);
  editor.query({ search: 'item(\\d+)', regexp: true, replace: '$1-$&' });
  assert(replaceMatches(editor.target, true)); assert.equal(editor.read(), '12-item12\r\n34-item34\n结束');
  assert(undo(editor.target)); assert.equal(editor.read(), raw);
  editor.query({ search: '\\n', replace: ' / ' });
  assert(replaceMatches(editor.target, true)); assert.equal(editor.read(), 'item12 / item34 / 结束');
  assert(undo(editor.target)); assert.equal(editor.read(), raw);
});

test('replace current selects an unselected match before editing, then advances', () => {
  const editor = fixture('zero cat cat');
  editor.query({ search: 'cat', replace: 'dog' });
  assert(replaceMatches(editor.target, false)); assert.equal(editor.read(), 'zero cat cat');
  assert.deepEqual(editor.target.state.selection.main, EditorSelection.range(5, 8));
  assert(replaceMatches(editor.target, false)); assert.equal(editor.read(), 'zero dog cat');
  assert(replaceMatches(editor.target, false)); assert.equal(editor.read(), 'zero dog dog');
  assert(undo(editor.target)); assert.equal(editor.read(), 'zero dog cat');
  assert(undo(editor.target)); assert.equal(editor.read(), 'zero cat cat');
});

test('invalid and empty patterns preserve document and have no replacement', () => {
  const editor = fixture('keep 🙂');
  for (const pattern of ['', '[']) {
    editor.query({ search: pattern, regexp: true, replace: 'deleted' });
    assert.equal(searchMatches(editor.target.state).ranges.length, 0);
    assert.equal(replaceMatches(editor.target, true), false);
    assert.equal(editor.read(), 'keep 🙂');
  }
});

test('read-only and composition protect replacements including direct library dispatch', () => {
  const readonly = fixture('cat', true);
  readonly.query({ search: 'cat', replace: 'dog' });
  assert.equal(replaceMatches(readonly.target, true), false); assert.equal(readonly.read(), 'cat');
  const editor = fixture('cat');
  editor.query({ search: 'cat', replace: 'dog' });
  editor.target.dispatch({ effects: changeComposition.of(true) });
  assert.equal(replaceMatches(editor.target, true), false);
  replaceAll(editor.target); assert.equal(editor.read(), 'cat');
  editor.target.dispatch({ effects: changeComposition.of(false) });
  assert(replaceMatches(editor.target, true)); assert.equal(editor.read(), 'dog');
});

test('zero-width Unicode regexes terminate and undo without corrupting surrogates', () => {
  const editor = fixture('🙂🙂');
  editor.query({ search: '(?=🙂)', regexp: true, replace: '前' });
  assert.equal(searchMatches(editor.target.state).ranges.length, 2);
  assert(replaceMatches(editor.target, true)); assert.equal(editor.read(), '前🙂前🙂');
  assert(undo(editor.target)); assert.equal(editor.read(), '🙂🙂');
});

test('excessive batch matches are reported and rejected without partial replacement', () => {
  const raw = 'x'.repeat(MATCH_LIMIT + 1), editor = fixture(raw);
  editor.query({ search: 'x', replace: 'y' });
  const matches = searchMatches(editor.target.state);
  assert.equal(matches.ranges.length, MATCH_LIMIT); assert.equal(matches.overflow, true);
  assert.equal(replaceMatches(editor.target, true), false); assert.equal(editor.read(), raw);
});
