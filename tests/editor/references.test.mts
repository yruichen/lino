import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { EditorState } from '@codemirror/state';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { syntaxTree, ensureSyntaxTree } from '@codemirror/language';
import { undoDepth } from '@codemirror/commands';
import { referenceSyntax } from '../../packages/editor/src/features/references/syntax.ts';
import { references, linkAt, anchoredHeadings } from '../../packages/editor/src/features/references/model.ts';
import { previewSources } from '../../packages/editor/src/features/media/model.ts';
import { setupDOM, settleDOM } from './dom.mts';
import { setLocale } from '../../packages/editor/src/localization/index.ts';
const fixture = setupDOM();
const { MarkdownEditor } = await import('../../packages/editor/src/engine/editor.ts');
after(() => fixture.dom.window.close());
function parsed(doc: string) {
  let state = EditorState.create({ doc, extensions: markdown({ base: markdownLanguage, extensions: [referenceSyntax] }) });
  ensureSyntaxTree(state, state.doc.length, 1000); state = state.update({}).state; return state;
}
test('reference syntax excludes code and metadata, preserves definitions/continuations and resolves first shared link definition', () => {
  const raw = '---\ntitle: "[^fake]"\n---\n\n# Heading\n\n[TOC]\n\nA[^note] and [**label**][ref].\n\n[^note]: First paragraph.\n\n    Continuation.\n\n[ref]: <a%20b.md#heading> "Title"\n[REF]: wrong.md\n\n```text\n[^code]: fake\n[TOC]\n```\n';
  const state = parsed(raw), index = references(state);
  assert.equal(index.notes.size, 1); assert.match(index.notes.get('note')!.content, /Continuation/);
  assert.equal(index.mentions.length, 1); assert.equal(index.toc.length, 1);
  assert.equal(index.links.length, 1); assert.equal(index.links[0].url, 'a%20b.md#heading'); assert.equal(index.links[0].title, 'Title');
  assert.equal(index.links[0].rawLabel, '**label**'); assert.equal(index.headings[0].anchor, 'heading');
  assert.equal(linkAt(state, raw.indexOf('label'))!.url, 'a%20b.md#heading');
  assert(syntaxTree(state).toString().includes('FrontMatter'));
});
test('anchor collisions remain unique even when a heading already contains a numeric suffix', () => {
  const entries = ['标题', '标题', '标题-1', '**Hello** world'].map((title, from) => ({ from, to: from + 1, level: 1, title }));
  assert.deepEqual(anchoredHeadings(entries).map(entry => entry.anchor), ['标题', '标题-1', '标题-1-1', 'hello-world']);
});
test('first shared definitions inside footnotes have original source ranges and are editable without losing the container', () => {
  const raw = '[link][shared]\n\n![image][shared]\n\n[^n]: note\n\n    [shared]: first.svg\n\n[shared]: later.svg';
  const mount = fixture.mount(), editor = new MarkdownEditor(mount, raw, () => {});
  try {
    const state = editor.view.state;
    assert.equal(linkAt(state, 2)?.url, 'first.svg'); assert.equal(previewSources(state).find(item => item.kind === 'image')?.text, 'first.svg');
    editor.select(2); assert(editor.command('edit-link-reference'));
    const input = mount.querySelector<HTMLInputElement>('input[name=link-url]')!;
    input.value = 'changed.svg'; input.dispatchEvent(new Event('input', { bubbles: true }));
    input.form!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    assert(editor.read().includes('    [shared]: <changed.svg>')); assert(editor.read().endsWith('[shared]: later.svg'));
    editor.command('undo'); assert.equal(editor.read(), raw);
  } finally { editor.destroy(); mount.remove(); }
});
test('an unclosed metadata delimiter remains a rule; configured editor parser recognizes only closed metadata', () => {
  const raw = '---\n# Visible\n\nA[^n]\n[^n]: note\n[TOC]';
  const state = parsed(raw);
  assert(!syntaxTree(state).toString().includes('FrontMatter'));
  assert.equal(references(state).headings.length, 1);
  assert.equal(references(state).notes.size, 1);
  assert.equal(references(state).toc.length, 1);
  const mount = fixture.mount(), editor = new MarkdownEditor(mount, '---\ntitle: [^fake]\n---\n\n# Real\n', () => {});
  try {
    ensureSyntaxTree(editor.view.state, editor.view.state.doc.length, 1000);
    assert(syntaxTree(editor.view.state).toString().includes('FrontMatter'));
    assert.equal(references(editor.view.state).mentions.length, 0);
  } finally { editor.destroy(); mount.remove(); }
});
test('link property drafts preserve Markdown labels, locale/focus and one undo; shared definitions update without rewriting occurrences', async () => {
  const raw = 'before\n\n[**bold**][ref]\n\n![image][ref]\n\n[ref]: <old.md> "old"';
  const mount = fixture.mount(), editor = new MarkdownEditor(mount, raw, () => {});
  try {
    editor.select(raw.indexOf('bold')); assert(editor.command('link-properties'));
    const url = mount.querySelector<HTMLInputElement>('input[name=link-url]')!;
    url.value = 'new file.md#标题'; url.dispatchEvent(new Event('input', { bubbles: true })); url.focus(); url.setSelectionRange(1, 3);
    setLocale('zh-Hans'); await settleDOM();
    const translated = mount.querySelector<HTMLInputElement>('input[name=link-url]')!;
    assert.equal(translated.value, 'new file.md#标题'); assert.equal(document.activeElement, translated);
    translated.form!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    assert.match(editor.read(), /\[\*\*bold\*\*\]\(<new%20file.md#标题> "old"\)/); assert(editor.read().endsWith('[ref]: <old.md> "old"'));
    assert.equal(undoDepth(editor.view.state), 1); editor.command('undo'); assert.equal(editor.read(), raw);
    editor.select(raw.indexOf('bold')); editor.command('edit-link-reference');
    const shared = mount.querySelector<HTMLInputElement>('input[name=link-url]')!; shared.value = 'shared.svg'; shared.dispatchEvent(new Event('input', { bubbles: true }));
    shared.form!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    assert(editor.read().includes('[**bold**][ref]')); assert(editor.read().includes('![image][ref]')); assert(editor.read().endsWith('[ref]: <shared.svg> "old"'));
    editor.command('undo'); assert.equal(editor.read(), raw);
  } finally { editor.destroy(); mount.remove(); setLocale('en'); }
});
test('property ranges map unrelated edits and refuse overlapping changes; readonly and composition do not insert', () => {
  const raw = 'prefix\n\n[text](a.md)', mount = fixture.mount(), editor = new MarkdownEditor(mount, raw, () => {});
  try {
    editor.select(raw.indexOf('text')); editor.command('link-properties');
    editor.view.dispatch({ changes: { from: 0, insert: 'new ' } });
    let url = mount.querySelector<HTMLInputElement>('input[name=link-url]')!; url.value = 'b.md'; url.dispatchEvent(new Event('input', { bubbles: true }));
    url.form!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true })); assert.equal(editor.read(), 'new prefix\n\n[text](<b.md>)');
    editor.select(editor.read().indexOf('text')); editor.command('link-properties');
    editor.view.dispatch({ changes: { from: editor.read().indexOf('text'), insert: 'changed' } });
    url = mount.querySelector<HTMLInputElement>('input[name=link-url]')!;
    assert(url.form!.querySelector<HTMLButtonElement>('button[type=submit]')!.disabled);
    const unchanged = editor.read(); url.form!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true })); assert.equal(editor.read(), unchanged);
    editor.setReadOnly(true); assert.equal(editor.command('insert-footnote'), false); assert.equal(editor.read(), unchanged);
  } finally { editor.destroy(); mount.remove(); }
});
test('footnote insertion, navigation, generated contents and local anchors share text/history and preserve mixed line endings', async () => {
  const raw = '# 标题\r\n\r\n[TOC]\n\n正文\r\n', mount = fixture.mount(), editor = new MarkdownEditor(mount, raw, () => {});
  try {
    editor.select(raw.indexOf('正文') - 1); editor.command('insert-footnote'); assert.match(editor.read(), /\[\^1\]/); assert.match(editor.read(), /\[\^1\]: /);
    editor.command('undo'); assert.equal(editor.read(), raw);
    editor.select(editor.view.state.doc.length); await settleDOM();
    const toc = mount.querySelector<HTMLButtonElement>('.ot-document-toc button')!; assert(toc); toc.click(); assert.equal(editor.view.state.selection.main.head, 0);
    assert.equal(editor.read(), raw); assert.equal(undoDepth(editor.view.state), 0);
  } finally { editor.destroy(); mount.remove(); }
});
