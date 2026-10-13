import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { EditorState, EditorSelection, type ChangeSpec } from '@codemirror/state';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { ensureSyntaxTree } from '@codemirror/language';
import { countText, headings, statistics, selectionCounts } from '../../packages/editor/src/features/analysis/model.ts';
import { setupDOM, settleDOM } from './dom.mts';
import { undoDepth } from '@codemirror/commands';
import { writingOptions } from '../../packages/editor/src/features/writing/state.ts';
import { navigateSourcePosition } from '../../packages/editor/src/features/navigation/line.ts';
const fixture = setupDOM();
const { MarkdownEditor } = await import('../../packages/editor/src/engine/editor.ts');
after(() => fixture.dom.window.close());

test('outline uses syntax ranges and excludes headings inside code while recognizing Setext and repeated titles', () => {
  const state = EditorState.create({ doc: '# Title\n\n```md\n# fake\n```\n\nSubtitle\n---\n\n> ## Title\n\n# Title\n', extensions: markdown({ base: markdownLanguage }) });
  assert(ensureSyntaxTree(state, state.doc.length, 100));
  // Publish the advanced parse into immutable state, as forceParsing does for
  // the real view; ensureSyntaxTree's returned tree alone is not that state.
  const parsed = state.update({}).state;
  const outline = headings(parsed);
  assert.equal(outline.complete, true);
  assert.deepEqual(outline.entries.map(h => [h.level, h.title]), [[1,'Title'],[2,'Subtitle'],[2,'Title'],[1,'Title']]);
  assert.equal(new Set(outline.entries.map(h => h.from)).size, 4);
  for (const heading of outline.entries) assert(state.doc.sliceString(heading.from, heading.to).includes(heading.title));
});
test('counts define Han, Unicode code points, source markup and selection semantics', () => {
  assert.deepEqual(countText('中文 hello 👩‍💻\n'), { words: 3, characters: 13, nonWhitespace: 10, lines: 2 });
  const state = EditorState.create({ doc: 'abc\n中文', selection: EditorSelection.single(4,6), extensions: statistics });
  assert.deepEqual(selectionCounts(state), countText('中文'));
  assert.deepEqual(state.field(statistics).total, countText(state.doc.toString()));
});
test('incremental line statistics match fresh counts through multiline, disjoint edits, blank lines and replacements', () => {
  let state = EditorState.create({ doc: 'first\n中文\nlast\n', extensions: statistics });
  const apply = (changes: ChangeSpec) => {
    state = state.update({ changes }).state;
    assert.deepEqual(state.field(statistics).total, countText(state.doc.toString()));
    assert.equal(state.field(statistics).total.lines, state.doc.lines);
  };
  apply([{ from: 1, to: 2, insert: 'x\ny' }, { from: 7, to: 8, insert: 'Z' }]);
  apply({ from: 0, to: state.doc.length, insert: '\n\n中\nabc' });
  apply({ from: 1, to: 4, insert: 'hello\nworld\n' });
  apply({ from: 0, to: state.doc.length, insert: '' });
  apply({ from: 0, insert: '\n'.repeat(100_000) });
});
test('outline filtering, collapse, jump and writing controls share the actual editor without changing source or history', async () => {
  const mount = fixture.mount(), editor = new MarkdownEditor(mount, '# First\n\n## Child\n\n# Last\n', () => {});
  try {
    assert(editor.command('toggle-outline')); await settleDOM();
    const sidebar = mount.querySelector<HTMLElement>('.ot-document-outline')!;
    assert.equal(sidebar.hidden, false);
    let headings = [...sidebar.querySelectorAll<HTMLButtonElement>('button[data-from]')]; assert.equal(headings.length, 3);
    sidebar.querySelector<HTMLButtonElement>('.ot-outline-row button')!.click();
    assert.equal(sidebar.querySelectorAll('button[data-from]').length, 2);
    const filter = sidebar.querySelector<HTMLInputElement>('input')!;
    filter.value = 'Child'; filter.dispatchEvent(new Event('input', { bubbles: true }));
    headings = [...sidebar.querySelectorAll<HTMLButtonElement>('button[data-from]')]; assert.equal(headings.length, 1);
    headings[0].click(); assert.equal(editor.view.state.doc.lineAt(editor.view.state.selection.main.head).text, '## Child');
    for (const command of ['focus-mode','typewriter-mode','zoom-in','zoom-reset'] as const) assert(editor.command(command));
    await settleDOM();
    assert(editor.view.state.field(writingOptions).focus); assert(editor.view.state.field(writingOptions).typewriter);
    assert.equal(editor.read(), '# First\n\n## Child\n\n# Last\n'); assert.equal(undoDepth(editor.view.state), 0);
    assert(mount.querySelector('.ot-statistics')!.textContent!.includes('words'));
    editor.select(0,7); assert(mount.querySelector('.ot-statistics')!.textContent!.includes('Selection'));
    assert(editor.command('toggle-statistics')); assert.equal(mount.querySelector('.ot-statistics'), null);
  } finally { editor.destroy(); mount.remove(); }
});
test('workspace-style line navigation reveals table source and focus mode also handles table widgets', async () => {
  const mount = fixture.mount(), raw = 'first\n\n| A | B |\n| --- | --- |\n| x | y |\n';
  const editor = new MarkdownEditor(mount, raw, () => {});
  try {
    editor.command('focus-mode'); await settleDOM();
    assert(mount.querySelector('.markdown-table.ot-unfocused'));
    const input = mount.querySelector<HTMLInputElement>('.markdown-table input')!; input.focus(); await settleDOM();
    assert(!mount.querySelector('.markdown-table.ot-unfocused'));
    assert(navigateSourcePosition(editor.view, editor.view.state.doc.line(5).from));
    assert.equal(editor.status().mode, 'source'); assert.equal(editor.view.state.doc.lineAt(editor.view.state.selection.main.head).number, 5);
    assert.equal(editor.read(), raw); assert.equal(undoDepth(editor.view.state), 0);
    assert.equal(navigateSourcePosition(editor.view, editor.view.state.doc.length + 1), false);
  } finally { editor.destroy(); mount.remove(); }
});
