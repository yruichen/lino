import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { setupDOM, settleDOM } from './dom.mts';
import { undoDepth } from '@codemirror/commands';
import { setLocale } from '../../packages/editor/src/localization/index.ts';
import { importImage } from '../../packages/editor/src/features/media/commands.ts';
import { AssetsClient } from '../../packages/protocol/src/client/assets.ts';
const fixture = setupDOM();
const { MarkdownEditor } = await import('../../packages/editor/src/engine/editor.ts');
after(() => fixture.dom.window.close());
test('formula and diagram insertion use original line ending metadata and one undo; readonly/IME preserve text', () => {
  const mount = fixture.mount(), editor = new MarkdownEditor(mount, 'start\r\nend', () => {});
  try {
    editor.select(6); assert(editor.command('math-block')); assert.match(editor.read(), /\$\$\r\nx = y\r\n\$\$/); assert.equal(undoDepth(editor.view.state), 1);
    assert(editor.command('undo')); assert.equal(editor.read(), 'start\r\nend');
    assert(editor.command('insert-diagram')); assert.match(editor.read(), /```mermaid\r\nflowchart LR/);
    assert(editor.command('undo')); editor.setReadOnly(true); assert.equal(editor.command('math-inline'), false); assert.equal(editor.read(), 'start\r\nend');
  } finally { editor.destroy(); mount.remove(); }
});
test('image properties hold their source range, preserve drafts across locale, and share undo without mutating a reference definition', async () => {
  const raw = '![alt][pic]\n\n[pic]: assets/test.png "title"', mount = fixture.mount(), editor = new MarkdownEditor(mount, raw, () => {});
  try {
    editor.select(3); editor.command('image-properties');
    let field = mount.querySelector<HTMLInputElement>('input[name=image-alt]')!; assert(field); field.focus(); field.value = '中文'; field.dispatchEvent(new Event('input', { bubbles: true })); field.setSelectionRange(1, 2);
    setLocale('zh-Hans'); await settleDOM(); field = mount.querySelector<HTMLInputElement>('input[name=image-alt]')!;
    assert.equal(field.value, '中文'); assert.equal(document.activeElement, field); assert.equal(editor.read(), raw); assert.equal(undoDepth(editor.view.state), 0);
    field.form!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true })); assert.match(editor.read(), /!\[中文\]\(<assets\/test.png> "title"\)/); assert(editor.read().endsWith('[pic]: assets/test.png "title"'));
    editor.command('source'); editor.command('undo'); assert.equal(editor.read(), raw);
  } finally { editor.destroy(); mount.remove(); setLocale('en'); }
});
test('async image insertion maps an unaffected anchor; deleted anchor or resource rebinding preserves the imported file without late text insertion', async () => {
  let release!: (value: string | null) => void;
  const mount = fixture.mount(), editor = new MarkdownEditor(mount, 'a\nb', () => {}, () => {}, async () => {}, {
    imageURL: source => `ot-image://local/image?source=${encodeURIComponent(source)}`,
    request: () => new Promise(resolve => { release = resolve; }),
  });
  try {
    editor.select(2); const first = importImage(editor.view, false); editor.view.dispatch({ changes: { from: 0, insert: 'x' } }); release('note.md.assets/a.png'); await first;
    assert.equal(editor.read(), 'xa\n![](<note.md.assets/a.png>)b'); editor.command('undo'); assert.equal(editor.read(), 'xa\nb');
    editor.select(3); const removed = importImage(editor.view, false); editor.view.dispatch({ changes: { from: 2, to: 4, insert: '' } }); release('retained.png'); await assert.rejects(removed, /retained.png/); assert.equal(editor.read(), 'xa');
    editor.select(2); const rebinding = importImage(editor.view, false); editor.refreshResources(); release('also-retained.png'); await assert.rejects(rebinding, /also-retained.png/); assert.equal(editor.read(), 'xa');
  } finally { editor.destroy(); mount.remove(); }
});
test('image preview uses a scoped host URL; remote image is not fetched before explicit load, source mode removes previews without changing text', async () => {
  const raw = 'before\n\n![local](assets/a.png)\n\n![remote](https://example.invalid/image.png)', mount = fixture.mount(), editor = new MarkdownEditor(mount, raw, () => {}, () => {}, async () => {}, {
    imageURL: source => `ot-image://local/image?source=${encodeURIComponent(source)}`, request: async () => null,
  });
  try {
    await settleDOM(); const local = mount.querySelector<HTMLImageElement>('.ot-preview-image img')!; assert(local.src.startsWith('ot-image://local/'), local.outerHTML);
    const previews = mount.querySelectorAll('.ot-preview-image'); assert.equal(previews.length, 2); assert.equal(previews[1].querySelector('img'), null);
    editor.command('source'); assert.equal(mount.querySelector('.ot-preview'), null); assert.equal(editor.read(), raw); assert.equal(undoDepth(editor.view.state), 0);
  } finally { editor.destroy(); mount.remove(); }
});
test('an unsaved relative image shows a localized location hint without a broken image; saving refreshes the preview and preserves text/history', async () => {
  const raw = 'before\n\n![日出](图片.assets/sample.svg)';
  const assets = new AssetsClient(() => {}); assets.setDocument('1', null);
  const mount = fixture.mount(), editor = new MarkdownEditor(mount, raw, () => {}, () => {}, async () => {}, assets);
  try {
    setLocale('zh-Hans'); await settleDOM();
    assert.equal(mount.querySelector('.ot-preview-image img'), null);
    assert.match(mount.querySelector('.ot-preview-image output')!.textContent!, /请打开原 Markdown 文件/);
    setLocale('en'); await settleDOM();
    assert.match(mount.querySelector('.ot-preview-image output')!.textContent!, /Open the original Markdown file/);
    assets.setDocument('1', '2'); editor.refreshResources(); await settleDOM();
    const image = mount.querySelector<HTMLImageElement>('.ot-preview-image img')!;
    assert(image); assert.equal(new URL(image.src).searchParams.get('file'), '2');
    assert.equal(editor.read(), raw); assert.equal(undoDepth(editor.view.state), 0);
    assets.setDocument('3', null); editor.refreshResources(); await settleDOM();
    assert.equal(mount.querySelector('.ot-preview-image img'), null);
    assert.equal(editor.read(), raw);
  } finally { editor.destroy(); assets.destroy(); mount.remove(); setLocale('en'); }
});
test('math conversion and formatting protection use the same undo; oversized diagram source remains editable', () => {
  const mount = fixture.mount(), editor = new MarkdownEditor(mount, 'a $x^2$ b', () => {});
  try {
    editor.select(4); assert.equal(editor.command('bold'), false); assert.equal(editor.read(), 'a $x^2$ b');
    assert(editor.command('math-block')); assert.match(editor.read(), /\$\$\nx\^2\n\$\$/); editor.command('undo'); assert.equal(editor.read(), 'a $x^2$ b');
    editor.select(4); assert(editor.command('math-inline')); assert.equal(editor.read(), 'a x^2 b'); editor.command('undo'); assert.equal(editor.read(), 'a $x^2$ b');
  } finally { editor.destroy(); mount.remove(); }
  const largeMount = fixture.mount(), raw = '```mermaid\n' + 'x'.repeat(50_001) + '\n```', large = new MarkdownEditor(largeMount, raw, () => {});
  try { assert.equal(large.read(), raw); assert.equal(large.command('preview-copy-source'), false); large.command('source'); assert.equal(large.read(), raw); }
  finally { large.destroy(); largeMount.remove(); }
});
test('image sizing is view-only and survives source toggles; insertion over selected text keeps one undo', async () => {
  const mount = fixture.mount(), editor = new MarkdownEditor(mount, 'selected', () => {});
  try {
    editor.select(0, 8); editor.command('image-properties');
    const source = mount.querySelector<HTMLInputElement>('input[name=image-source]')!; source.value = 'assets/a.png'; source.dispatchEvent(new Event('input', { bubbles: true }));
    source.form!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true })); assert.equal(editor.read(), '![selected](<assets/a.png>)');
    await settleDOM(); const before = undoDepth(editor.view.state);
    assert(editor.command('image-smaller'));
    assert.equal(mount.querySelector<HTMLElement>('.ot-preview-image')!.dataset.imageScale, '0.8'); assert.equal(undoDepth(editor.view.state), before);
    editor.command('source'); editor.command('visual'); assert.equal(mount.querySelector<HTMLElement>('.ot-preview-image')!.dataset.imageScale, '0.8');
    editor.command('undo'); assert.equal(editor.read(), 'selected');
  } finally { editor.destroy(); mount.remove(); }
});
test('late preview output cannot replace edited source; cancellation stays observable and save barrier waits for import', async () => {
  let release!: (result: { html: string; mathml: string }) => void;
  const win = fixture.dom.window as typeof fixture.dom.window & { LinoMath?: unknown };
  win.LinoMath = { render: async (input: { text: string }) => input.text === 'old' ? new Promise(resolve => { release = resolve; }) : { html: '<span>current-render</span>', mathml: '<math />' } };
  const mount = fixture.mount(), raw = 'before $old$ after', editor = new MarkdownEditor(mount, raw, () => {});
  try {
    await settleDOM(); document.querySelector<HTMLScriptElement>('script[src="math.js"]')!.dispatchEvent(new Event('load'));
    document.querySelector<HTMLLinkElement>('link[href="math.css"]')!.dispatchEvent(new Event('load')); await settleDOM();
    editor.view.dispatch({ changes: { from: 8, to: 11, insert: 'new' } }); release({ html: '<span>obsolete-render</span>', mathml: '<math />' }); await settleDOM();
    assert.equal(editor.read(), 'before $new$ after'); assert(!mount.textContent!.includes('obsolete-render')); assert(mount.textContent!.includes('current-render'));
    editor.select(9); await settleDOM(); assert(editor.command('preview-cancel')); assert(mount.textContent!.includes('cancelled')); assert(!mount.textContent!.includes('current-render'));
  } finally { editor.destroy(); mount.remove(); }
  let finish!: (path: string | null) => void;
  const importMount = fixture.mount(), importing = new MarkdownEditor(importMount, '', () => {}, () => {}, async () => {}, {
    imageURL: value => value, request: () => new Promise(resolve => { finish = resolve; }),
  });
  try {
    const work = importImage(importing.view, false); let settled = false;
    const barrier = importing.settleResources().then(() => { settled = true; }); await Promise.resolve(); assert.equal(settled, false);
    finish('image.png'); await work; await barrier; assert.equal(settled, true); assert.equal(importing.read(), '![](<image.png>)');
  } finally { importing.destroy(); importMount.remove(); }
});
