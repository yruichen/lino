import assert from 'node:assert/strict';
import { test } from 'node:test';
import { EditorState, EditorSelection, type TransactionSpec } from '@codemirror/state';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { ensureSyntaxTree } from '@codemirror/language';
import { history, undo, redo, undoDepth } from '@codemirror/commands';
import { sourceDocument } from '../../packages/editor/src/transactions/line-endings.ts';
import { modeState, changeMode, compositionState, changeComposition } from '../../packages/editor/src/features/source-mode/state.ts';
import { codeBlockAt, codeContents } from '../../packages/editor/src/features/code/model.ts';
import { codeLanguageTransaction, codeIndentTransaction } from '../../packages/editor/src/features/code/commands.ts';
import { languageForCode } from '../../packages/editor/src/features/code/languages.ts';
import { codeOptions, codeViewTransaction } from '../../packages/editor/src/features/code/state.ts';

function editor(raw: string, selection?: { anchor: number; head?: number }) {
  const source = sourceDocument(raw);
  let state = EditorState.create({ doc: source.doc, selection, extensions: [
    source.extension, markdown({ base: markdownLanguage, codeLanguages: languageForCode }), history(), modeState, compositionState, codeOptions,
  ] });
  return {
    get state() { return state; },
    dispatch(spec: TransactionSpec) { state = state.update(spec).state; },
    read: () => source.read(state),
  };
}
test('language changes preserve fence kind/length, metadata, Unicode and original endings in one history', () => {
  const raw = '前言\r\n\r\n````js {#id .class}\r\nconst 中 = "👩🏽‍💻";\n```inside\r\n````\r\n\r\n尾言';
  const e = editor(raw); e.dispatch({ selection: { anchor: e.state.doc.toString().indexOf('const') + 6 } });
  e.dispatch(codeLanguageTransaction(e.state, 'python')!);
  assert.equal(e.read(), raw.replace('````js', '````python'));
  assert.equal(undoDepth(e.state), 1);
  e.dispatch({ effects: changeMode.of('source') });
  assert(undo(e)); assert.equal(e.read(), raw);
  e.dispatch({ effects: changeMode.of('visual') });
  assert(redo(e)); assert.equal(e.read(), raw.replace('````js', '````python'));
});
test('plain language never promotes retained info attributes to a language token', () => {
  const e = editor('~~~python {#source}\na\n~~~', { anchor: 20 });
  e.dispatch(codeLanguageTransaction(e.state, '')!);
  assert.equal(e.read(), '~~~text {#source}\na\n~~~');
  assert.equal(codeBlockAt(e.state)!.language, 'text');
  const plain = editor('```python\na\n```', { anchor: 10 });
  plain.dispatch(codeLanguageTransaction(plain.state, '')!);
  assert.equal(plain.read(), '```\na\n```');
});
test('nested code language changes only its info token; invalid identifiers cannot inject Markdown', () => {
  const raw = '> ```rust title\n> let x = 1;\n> ```';
  const e = editor(raw, { anchor: raw.indexOf('let') });
  for (const invalid of ['x\ny', 'x y', '```', '~~~', 'x'.repeat(81)]) assert.throws(() => codeLanguageTransaction(e.state, invalid));
  assert.equal(e.read(), raw);
  e.dispatch(codeLanguageTransaction(e.state, 'future-language')!);
  assert.equal(e.read(), raw.replace('rust', 'future-language'));
  assert.equal(languageForCode('future-language'), null);
});
test('code copying excludes fences and containers, preserves blank lines and code indentation', () => {
  for (const [raw, expected] of [
    ['```js\nconst 中 = "👩🏽‍💻";\n\n```', 'const 中 = "👩🏽‍💻";\n\n'],
    ['> ```js\n>  a\n> b\n>\n> c\n> ```', ' a\nb\n\nc\n'],
    ['- item\n\n  ```py\n    a\n  b\n  ```', '  a\nb\n'],
    ['  ```js\n  a\n b\n  ```', 'a\nb\n'],
    ['```\ntext', 'text'],
    ['```\n```', ''],
    ['    code\n    next', 'code\nnext'],
  ]) {
    const e = editor(raw); const pos = raw.indexOf('```') >= 0 ? raw.indexOf('```') : 4;
    e.dispatch({ selection: { anchor: pos } });
    const block = codeBlockAt(e.state); assert(block, raw);
    assert.equal(codeContents(e.state, block), expected, raw);
  }
});
test('indent/outdent operate on selected code lines only and retain container prefixes', () => {
  for (const raw of ['```js\na\nb\n```\n\noutside', '> ```js\n> a\n> b\n> ```\n\noutside']) {
    const e = editor(raw);
    const a = raw.indexOf('a\n'), b = raw.indexOf('b\n');
    e.dispatch({ selection: EditorSelection.single(a, b + 1) });
    e.dispatch(codeIndentTransaction(e.state, 1)!);
    assert.equal(e.read(), raw.replace('a\n', '  a\n').replace('b\n', '  b\n'));
    assert(undo(e)); assert.equal(e.read(), raw);
    assert(redo(e));
    e.dispatch(codeIndentTransaction(e.state, -1)!); assert.equal(e.read(), raw);
  }
});
test('cross-block ranges, fences and indented language changes have explicit boundaries', () => {
  const e = editor('```js\na\n```\n\noutside', { anchor: 6, head: 20 });
  assert.throws(() => codeIndentTransaction(e.state, 1));
  const indented = editor('    a\n    b', { anchor: 4 });
  assert.throws(() => codeLanguageTransaction(indented.state, 'python'));
  assert.equal(indented.read(), '    a\n    b');
  assert.equal(codeBlockAt(editor('ordinary text').state), undefined);
});
test('read-only and composition block changes, while view options do not dirty content or enter history', () => {
  const raw = '```js\na\n```';
  const e = editor(raw, { anchor: 6 });
  e.dispatch({ effects: changeComposition.of(true) });
  assert.equal(codeLanguageTransaction(e.state, 'rust'), undefined);
  assert.equal(codeIndentTransaction(e.state, 1), undefined);
  e.dispatch({ effects: changeComposition.of(false) });
  e.dispatch(codeViewTransaction({ numbers: true, wrap: false }));
  assert.deepEqual(e.state.field(codeOptions), { numbers: true, wrap: false });
  assert.equal(e.read(), raw); assert.equal(undoDepth(e.state), 0);
  const readonly = EditorState.create({ doc: raw, selection: { anchor: 6 }, extensions: [markdown(), EditorState.readOnly.of(true)] });
  assert.equal(codeLanguageTransaction(readonly, 'rust'), undefined);
  assert.equal(codeIndentTransaction(readonly, 1), undefined);
});
test('known language aliases mount syntax parsers, and unknown languages retain plain code', () => {
  for (const [tag, code, token] of [
    ['js', 'const answer = 42;', 'answer'], ['ts', 'const answer: number = 42;', 'answer'],
    ['py', 'def answer():\n    return 42', 'answer'], ['rs', 'fn answer() -> i32 { 42 }', 'answer'],
    ['json', '{"answer": 42}', 'answer'],
  ]) {
    const raw = '```' + tag + '\n' + code + '\n```', e = editor(raw);
    const tree = ensureSyntaxTree(e.state, e.state.doc.length, 1000)!;
    assert.notEqual(tree.resolveInner(raw.indexOf(token) + 1).name, 'CodeText', tag);
  }
  assert.equal(languageForCode('unknown-tag'), null);
  assert.equal(languageForCode('JAVASCRIPT extra metadata'), languageForCode('js'));
});
