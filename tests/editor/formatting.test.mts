import { setLocale } from '../../packages/editor/src/localization/index.ts';
before(() => setLocale('zh-Hans'));
after(() => setLocale('en'));
import assert from 'node:assert/strict';
import { before, after, test } from 'node:test';
import { EditorSelection, EditorState, Transaction, type TransactionSpec } from '@codemirror/state';
import { history, undo } from '@codemirror/commands';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { sourceDocument } from '../../packages/editor/src/transactions/line-endings.ts';
import { changeComposition, compositionState } from '../../packages/editor/src/features/source-mode/state.ts';
import { formattingTransaction, type FormatCommand } from '../../packages/editor/src/features/markdown/commands.ts';

function fixture(raw: string, readOnly = false) {
  const source = sourceDocument(raw);
  let state = EditorState.create({ doc: source.doc, extensions: [source.extension, markdown({ base: markdownLanguage }), history(), compositionState, EditorState.readOnly.of(readOnly)] });
  const target = { get state() { return state; }, dispatch(transaction: Transaction | TransactionSpec) { state = transaction instanceof Transaction ? transaction.state : state.update(transaction).state; } };
  return { target, read: () => source.read(state),
    select(from: number, to = from) { target.dispatch({ selection: EditorSelection.single(from, to) }); },
    format(command: FormatCommand) { const transaction = formattingTransaction(state, command); if (transaction) target.dispatch(transaction); return !!transaction; },
  };
}

test('inline formatting wraps Unicode selection, toggles and shares one undo history', () => {
  for (const [command, mark] of [['bold', '**'], ['italic', '*'], ['strikethrough', '~~']] as const) {
    const editor = fixture('前言 中文🙂 尾言');
    editor.select(3, 7); assert(editor.format(command));
    assert.equal(editor.read(), `前言 ${mark}中文🙂${mark} 尾言`);
    assert(editor.format(command)); assert.equal(editor.read(), '前言 中文🙂 尾言');
    assert(undo(editor.target)); assert.equal(editor.read(), `前言 ${mark}中文🙂${mark} 尾言`);
    assert(undo(editor.target)); assert.equal(editor.read(), '前言 中文🙂 尾言');
  }
});

test('multi-line inline formatting preserves blank lines and original newline bytes', () => {
  const raw = '甲\r\n\r\n乙🙂\n尾', editor = fixture(raw);
  editor.select(0, editor.target.state.doc.line(4).from);
  editor.format('bold'); assert.equal(editor.read(), '**甲**\r\n\r\n**乙🙂**\n尾');
  editor.format('bold'); assert.equal(editor.read(), raw);
  assert(undo(editor.target)); assert.equal(editor.read(), '**甲**\r\n\r\n**乙🙂**\n尾');
  assert(undo(editor.target)); assert.equal(editor.read(), raw);
});

test('inline code uses a sufficient delimiter and restores literal backticks on toggle', () => {
  const editor = fixture('`x` 🙂');
  editor.select(0, editor.target.state.doc.length);
  editor.format('inline-code'); assert.equal(editor.read(), '`` `x` 🙂 ``');
  editor.format('inline-code'); assert.equal(editor.read(), '`x` 🙂');
  assert(undo(editor.target)); assert.equal(editor.read(), '`` `x` 🙂 ``');
});

test('empty selections create editable placeholders and links select destination', () => {
  const editor = fixture(''); editor.format('bold'); assert.equal(editor.read(), '**文字**');
  assert.equal(editor.target.state.sliceDoc(editor.target.state.selection.main.from, editor.target.state.selection.main.to), '文字');
  assert(undo(editor.target)); editor.select(0); editor.format('link'); assert.equal(editor.read(), '[链接文字](https://example.com)');
  assert.equal(editor.target.state.sliceDoc(editor.target.state.selection.main.from, editor.target.state.selection.main.to), '链接文字');
  const link = fixture('中文🙂'); link.select(0, 4); link.format('link'); assert.equal(link.read(), '[中文🙂](https://example.com)');
  assert.equal(link.target.state.sliceDoc(link.target.state.selection.main.from, link.target.state.selection.main.to), 'https://example.com');
  link.select(2); link.format('link'); assert.equal(link.target.state.sliceDoc(link.target.state.selection.main.from, link.target.state.selection.main.to), 'https://example.com');
});

test('heading levels replace ATX markers, preserve list/quote prefixes and toggle', () => {
  for (let level = 1; level <= 6; level++) {
    const raw = '> - ## 中文🙂', editor = fixture(raw); editor.select(editor.target.state.doc.length);
    editor.format(`heading-${level}` as FormatCommand);
    assert.equal(editor.read(), level === 2 ? '> - 中文🙂' : '> - ' + '#'.repeat(level) + ' 中文🙂');
    assert(undo(editor.target)); assert.equal(editor.read(), raw);
  }
});

test('flat list conversion changes only prefixes and keeps checked task content', () => {
  const raw = '甲\r\n乙🙂\n尾', editor = fixture(raw);
  editor.select(0, editor.target.state.doc.length); editor.format('ordered-list');
  assert.equal(editor.read(), '1. 甲\r\n2. 乙🙂\n3. 尾');
  editor.format('task-list'); assert.equal(editor.read(), '- [ ] 甲\r\n- [ ] 乙🙂\n- [ ] 尾');
  editor.format('task-list'); assert.equal(editor.read(), raw);
  assert(undo(editor.target)); assert.equal(editor.read(), '- [ ] 甲\r\n- [ ] 乙🙂\n- [ ] 尾');
  const checked = fixture('> - [x] 完成'); checked.select(checked.target.state.doc.length); checked.format('bullet-list');
  assert.equal(checked.read(), '> - 完成'); assert(undo(checked.target)); assert.equal(checked.read(), '> - [x] 完成');
});

test('quote toggles whole blocks and excludes an unselected final line', () => {
  const raw = '甲\r\n乙\n\n尾', editor = fixture(raw);
  editor.select(0, editor.target.state.doc.line(3).from); editor.format('blockquote');
  assert.equal(editor.read(), '> 甲\r\n> 乙\n\n尾');
  editor.format('blockquote'); assert.equal(editor.read(), raw);
  assert(undo(editor.target)); assert.equal(editor.read(), '> 甲\r\n> 乙\n\n尾');
});

test('code blocks choose collision-free fences, toggle content and undo exact bytes', () => {
  const raw = 'a `x`\r\nb🙂\n尾', editor = fixture(raw);
  editor.select(0, editor.target.state.doc.line(3).from); editor.format('code-block');
  assert.equal(editor.read(), '```\r\na `x`\r\nb🙂\r\n```\n尾');
  editor.format('code-block'); assert.equal(editor.read(), raw);
  assert(undo(editor.target)); assert.equal(editor.read(), '```\r\na `x`\r\nb🙂\r\n```\n尾');
  const blank = fixture(''); blank.format('code-block'); assert.equal(blank.read(), '```\n\n```');
  blank.format('code-block'); assert.equal(blank.read(), '');
});

test('unsupported complex structures and invalid ranges are rejected before mutation', () => {
  for (const [raw, command, position] of [
    ['- parent\n  - child', 'ordered-list', 3],
    ['a\n===', 'heading-2', 1],
    ['| A |\n| --- |\n| cell |', 'bold', 17],
    ['```\ncode', 'code-block', 5],
    ['> - parent\n>   - child', 'blockquote', 6],
  ] as const) {
    const editor = fixture(raw); editor.select(position); assert.throws(() => editor.format(command)); assert.equal(editor.read(), raw);
  }
  const emoji = fixture('🙂'); emoji.select(1); assert.throws(() => emoji.format('bold')); assert.equal(emoji.read(), '🙂');
  const multiline = fixture('one\ntwo'); multiline.select(0, 7); assert.throws(() => multiline.format('inline-code')); assert.throws(() => multiline.format('link'));
});

test('formatting obeys read-only and IME state without adding history', () => {
  const readonly = fixture('甲', true); assert.equal(readonly.format('bold'), false); assert.equal(readonly.read(), '甲');
  const editor = fixture('甲'); editor.target.dispatch({ effects: changeComposition.of(true) });
  assert.equal(editor.format('bullet-list'), false); assert.equal(editor.read(), '甲'); assert.equal(undo(editor.target), false);
  editor.target.dispatch({ effects: changeComposition.of(false) }); assert(editor.format('bullet-list')); assert.equal(editor.read(), '- 甲');
});

test('heading toggles remove optional closing markers and quotes include lazy continuation', () => {
  const heading = fixture('## 中文 ##'); heading.select(5); heading.format('heading-2'); assert.equal(heading.read(), '中文');
  assert(undo(heading.target)); assert.equal(heading.read(), '## 中文 ##');
  const quote = fixture('one\ntwo\n\nother'); quote.select(1); quote.format('blockquote'); assert.equal(quote.read(), '> one\n> two\n\nother');
  quote.format('blockquote'); assert.equal(quote.read(), 'one\ntwo\n\nother');
});

test('link insertion rejects literal code contexts and task conversion keeps checked state', () => {
  const code = fixture('`code`'); code.select(2); assert.throws(() => code.format('link')); assert.equal(code.read(), '`code`');
  const tasks = fixture('- [x] done\n\nnew'); tasks.select(0, tasks.target.state.doc.length); tasks.format('task-list');
  assert.equal(tasks.read(), '- [x] done\n\n- [ ] new');
  assert(undo(tasks.target)); assert.equal(tasks.read(), '- [x] done\n\nnew');
});

test('block prefixes place an empty caret after the marker and typing advances in source order', () => {
  const cases: { raw: string; position: number; command: FormatCommand; prefix: string }[] = [
    ...([1, 2, 3, 4, 5, 6] as const).map(level => ({ raw: '', position: 0, command: `heading-${level}` as FormatCommand, prefix: '#'.repeat(level) + ' ' })),
    { raw: '前\r\n\r\n后', position: 2, command: 'heading-3', prefix: '### ' },
    { raw: '🙂正文', position: 0, command: 'heading-2', prefix: '## ' },
    { raw: '- ', position: 2, command: 'heading-2', prefix: '## ' },
    { raw: '> - ', position: 4, command: 'heading-2', prefix: '## ' },
    { raw: '', position: 0, command: 'bullet-list', prefix: '- ' },
    { raw: '', position: 0, command: 'ordered-list', prefix: '1. ' },
    { raw: '', position: 0, command: 'task-list', prefix: '- [ ] ' },
    { raw: '正文', position: 0, command: 'blockquote', prefix: '> ' },
    { raw: '', position: 0, command: 'blockquote', prefix: '> ' },
    { raw: '上文\r\n\r\n下文', position: 3, command: 'blockquote', prefix: '> ' },
  ];
  for (const entry of cases) {
    const editor = fixture(entry.raw); editor.select(entry.position); editor.format(entry.command);
    let caret = entry.position + entry.prefix.length;
    assert.equal(editor.target.state.selection.main.empty, true, entry.command);
    assert.equal(editor.target.state.selection.main.head, caret, `${entry.command} in ${JSON.stringify(entry.raw)}`);
    const original = editor.target.state.doc.toString();
    let inserted = '';
    for (const character of ['甲', '🙂', '乙']) {
      editor.target.dispatch({ ...editor.target.state.replaceSelection(character), userEvent: 'input.type' });
      inserted += character; caret += character.length;
      assert.equal(editor.target.state.selection.main.head, caret);
      assert.equal(editor.target.state.selection.main.empty, true);
      const at = entry.position + entry.prefix.length;
      assert.equal(editor.target.state.doc.toString(), original.slice(0, at) + inserted + original.slice(at));
    }
  }
});

test('heading conversion and reverse selections preserve the selected content instead of selecting markers', () => {
  for (const reversed of [false, true]) {
    const editor = fixture('中文🙂'); editor.select(reversed ? 4 : 0, reversed ? 0 : 4); editor.format('heading-3');
    const selection = editor.target.state.selection.main;
    assert.equal(editor.target.state.sliceDoc(selection.from, selection.to), '中文🙂');
    assert.equal(selection.from, 4); assert.equal(selection.to, 8);
    assert.equal(selection.anchor > selection.head, reversed);
    editor.target.dispatch(editor.target.state.replaceSelection('新🙂'));
    assert.equal(editor.read(), '### 新🙂'); assert.equal(editor.target.state.selection.main.head, 7);
  }
  const existing = fixture('# 旧🙂'); existing.select(2); existing.format('heading-4');
  assert.equal(existing.target.state.selection.main.head, 5);
  existing.target.dispatch(existing.target.state.replaceSelection('新'));
  assert.equal(existing.read(), '#### 新旧🙂');
  existing.format('heading-4');
  assert.equal(existing.target.state.selection.main.head, 1); assert.equal(existing.read(), '新旧🙂');
});

test('code and link explicit editing selections remain usable after a format command', () => {
  const code = fixture(''); code.format('code-block');
  assert.equal(code.target.state.selection.main.head, 4);
  for (const character of ['a', '🙂', 'b']) code.target.dispatch(code.target.state.replaceSelection(character));
  assert.equal(code.read(), '```\na🙂b\n```'); assert.equal(code.target.state.selection.main.head, 8);
  const inline = fixture(''); inline.format('inline-code');
  assert.equal(inline.target.state.sliceDoc(inline.target.state.selection.main.from, inline.target.state.selection.main.to), '代码');
  inline.target.dispatch(inline.target.state.replaceSelection('a🙂'));
  assert.equal(inline.read(), '`a🙂`'); assert.equal(inline.target.state.selection.main.head, 4);
  const link = fixture('文字'); link.select(0, 2); link.format('link');
  assert.equal(link.target.state.sliceDoc(link.target.state.selection.main.from, link.target.state.selection.main.to), 'https://example.com');
  link.target.dispatch(link.target.state.replaceSelection('https://example.org'));
  assert.equal(link.read(), '[文字](https://example.org)');
  assert.equal(link.target.state.selection.main.head, '[文字](https://example.org'.length);
});
