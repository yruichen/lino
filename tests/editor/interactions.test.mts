import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { undoDepth } from '@codemirror/commands';
import { querySummary } from '../../packages/editor/src/features/search/state.ts';
import { presentationSelection } from '../../packages/editor/src/controls/pointer.ts';
import { setupDOM, settleDOM } from './dom.mts';
const fixture = setupDOM();
const { MarkdownEditor } = await import('../../packages/editor/src/engine/editor.ts');
after(() => fixture.dom.window.close());

test('clicking media edits its existing source in place, keeps one history and leaves secondary actions in a context menu', () => {
  const raw = 'start\n\n![alt](local.svg)\n\n$x+1$\n\nend', mount = fixture.mount();
  const events: import('../../packages/protocol/src/client/editor-host.ts').EditorHostEvent[] = [];
  const editor = new MarkdownEditor(mount, raw, event => events.push(event));
  try {
    assert.equal(mount.querySelector('.ot-preview-actions'), null);
    const image = mount.querySelector<HTMLElement>('.ot-preview-image')!;
    let snapshots = 0;
    const snapshot = editor.view.scrollSnapshot.bind(editor.view);
    editor.view.scrollSnapshot = () => { snapshots++; return snapshot(); };
    const down = new fixture.dom.window.MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 0 });
    image.dispatchEvent(down); assert(down.defaultPrevented);
    image.click(); assert.equal(editor.view.state.selection.main.head, raw.indexOf('alt'));
    assert.equal(snapshots, 1);
    assert.equal(editor.view.hasFocus, true); assert.equal(editor.read(), raw);
    editor.view.dispatch({ changes: { from: editor.view.state.selection.main.head, insert: 'new ' } });
    assert.match(editor.read(), /!\[new alt\]/); assert(editor.command('undo')); assert.equal(editor.read(), raw);
    mount.querySelector<HTMLElement>('.ot-preview-inline.ot-preview-math')!.click();
    assert.equal(editor.view.state.selection.main.head, raw.indexOf('x+1'));
    assert.equal(mount.querySelector('.ot-media-panel'), null);
    const menu = new fixture.dom.window.MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 12, clientY: 20 });
    mount.querySelector('.ot-preview-math')!.dispatchEvent(menu);
    assert(menu.defaultPrevented); assert(events.some(event => event.kind === 'context-menu' && event.context === 'math'));
    assert.equal(editor.read(), raw); assert.equal(undoDepth(editor.view.state), 0);
  } finally { editor.destroy(); mount.remove(); }
});

test('mouse selection resolves before visual markup is revealed; release preserves the accepted selection and history', async () => {
  const raw = 'start\n\n**body**\n\nend', mount = fixture.mount(), editor = new MarkdownEditor(mount, raw, () => {});
  try {
    const position = raw.indexOf('body') + 2;
    // Geometry is synthetic here. Exercise CodeMirror's actual gesture/event
    // lifecycle without claiming this fixture proves WebKit hit testing.
    editor.view.posAndSideAtCoords = () => ({ pos: position, assoc: 1 });
    const line = [...editor.view.contentDOM.querySelectorAll('.cm-line')].find(node => node.textContent === 'body')!;
    assert(line);
    line.dispatchEvent(new fixture.dom.window.MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 0, detail: 1 }));
    assert.equal(editor.view.state.selection.main.head, position);
    assert.equal(presentationSelection(editor.view.state).main.head, 0);
    assert(!editor.view.contentDOM.textContent!.includes('**body**'));
    document.dispatchEvent(new fixture.dom.window.MouseEvent('mouseup', { bubbles: true, button: 0 }));
    await settleDOM();
    assert.equal(presentationSelection(editor.view.state).main.head, position);
    assert(editor.view.contentDOM.textContent!.includes('**body**'));
    assert.equal(editor.view.state.selection.main.head, position);
    assert.equal(editor.read(), raw); assert.equal(undoDepth(editor.view.state), 0);
  } finally { editor.destroy(); mount.remove(); }
});

test('an old image source does not collapse above the pointer while a new text selection is being resolved', async () => {
  const raw = 'start\n\n![alt](local.svg)\n\nbody\n\nend', mount = fixture.mount(), editor = new MarkdownEditor(mount, raw, () => {});
  try {
    editor.select(raw.indexOf('alt'));
    assert(editor.view.contentDOM.textContent!.includes('![alt]'));
    const position = raw.indexOf('body') + 2;
    editor.view.posAndSideAtCoords = () => ({ pos: position, assoc: 1 });
    const line = [...editor.view.contentDOM.querySelectorAll('.cm-line')].find(node => node.textContent === 'body')!;
    line.dispatchEvent(new fixture.dom.window.MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 0, detail: 1 }));
    assert.equal(editor.view.state.selection.main.head, position);
    assert(editor.view.contentDOM.textContent!.includes('![alt]'));
    document.dispatchEvent(new fixture.dom.window.MouseEvent('mouseup', { bubbles: true, button: 0 })); await settleDOM();
    assert(!editor.view.contentDOM.textContent!.includes('![alt]'));
    assert.equal(editor.view.state.selection.main.head, position); assert.equal(editor.read(), raw); assert.equal(undoDepth(editor.view.state), 0);
  } finally { editor.destroy(); mount.remove(); }
});

test('visual code hides its fences and info, edits actual body text, and exposes language editing only on request', () => {
  const raw = 'start\n\n```RUST title\nlet x = 1;\n```\n\nend', mount = fixture.mount(), editor = new MarkdownEditor(mount, raw, () => {});
  try {
    assert(!editor.view.contentDOM.textContent!.includes('```')); assert(!editor.view.contentDOM.textContent!.includes('RUST title'));
    assert.equal(mount.querySelector('.ot-code-language')!.textContent, 'RUST');
    editor.select(raw.indexOf('let')); assert.equal(mount.querySelector('.ot-code-tools'), null);
    editor.view.dispatch({ changes: { from: raw.indexOf('1;'), to: raw.indexOf('1;') + 1, insert: '2' } });
    assert.equal(editor.read(), raw.replace('1;', '2;')); assert.equal(undoDepth(editor.view.state), 1);
    editor.command('source'); assert(editor.view.contentDOM.textContent!.includes('```RUST title'));
    editor.command('undo'); assert.equal(editor.read(), raw);
    editor.command('visual'); mount.querySelector<HTMLButtonElement>('.ot-code-language')!.click();
    assert(mount.querySelector('input[name=code-language]')); assert.equal(mount.querySelector('button[name=code-indent]'), null);
  } finally { editor.destroy(); mount.remove(); }
});

test('native search projects one query, ignores older input, toggles closed and replaces through the document history', async () => {
  const raw = 'cat dog cat', mount = fixture.mount();
  const editor = new MarkdownEditor(mount, raw, () => {}, () => {}, undefined, undefined, { nativeSearch: true });
  try {
    assert(editor.command('toggle-find')); assert.equal(editor.status().search.open, true);
    assert.equal(mount.querySelector<HTMLInputElement>('input[name=search]')!.hidden, true);
    editor.search('cat', '2'); editor.search('dog', '1');
    assert.equal(editor.status().search.text, 'cat'); assert.equal(editor.status().search.count, 2); assert.equal(editor.status().search.querySequence, '2');
    const cached = editor.view.state.field(querySummary);
    editor.select(4); assert.equal(editor.view.state.field(querySummary), cached);
    editor.command('find-next'); assert.equal(editor.status().search.index, 2);
    editor.command('replace');
    const replacement = mount.querySelector<HTMLInputElement>('input[name=replace]')!;
    replacement.value = 'bird'; replacement.dispatchEvent(new Event('input', { bubbles: true }));
    mount.querySelector<HTMLButtonElement>('button[name=replace-all]')!.click();
    assert.equal(editor.read(), 'bird dog bird'); assert.equal(undoDepth(editor.view.state), 1);
    editor.command('undo'); assert.equal(editor.read(), raw);
    const options = mount.querySelector<HTMLButtonElement>('button[name=options]')!;
    options.click(); assert.equal(mount.querySelector<HTMLElement>('.ot-search-options')!.hidden, false);
    editor.command('toggle-find'); assert.equal(editor.status().search.open, false);
    await settleDOM(); assert.equal(mount.querySelector('.ot-search'), null); assert.equal(editor.read(), raw);
  } finally { editor.destroy(); mount.remove(); }
});

test('opening search preserves rendered components; navigation reveals only the matched table and replacement shares undo', async () => {
  const raw = 'start\n\n| A |\n| --- |\n| needle |\n\n| B |\n| --- |\n| other |\n\n![alt](local.svg)\n\n$x+1$\n\n[TOC]\n\n# Heading';
  const mount = fixture.mount(), editor = new MarkdownEditor(mount, raw, () => {}, () => {}, undefined, undefined, { nativeSearch: true });
  try {
    const tables = [...mount.querySelectorAll('.markdown-table')], image = mount.querySelector('.ot-preview-image'), math = mount.querySelector('.ot-preview-math'), toc = mount.querySelector('.ot-document-toc');
    assert.equal(tables.length, 2); assert(image && math && toc);
    editor.command('find');
    assert.equal(editor.status().mode, 'visual'); assert.equal(editor.read(), raw);
    assert.deepEqual([...mount.querySelectorAll('.markdown-table')], tables);
    assert.equal(mount.querySelector('.ot-preview-image'), image);
    assert.equal(mount.querySelector('.ot-preview-math'), math);
    assert.equal(mount.querySelector('.ot-document-toc'), toc);
    editor.search('needle', '1');
    assert.deepEqual([...mount.querySelectorAll('.markdown-table')], tables);
    editor.command('find-next');
    assert.equal(editor.view.state.sliceDoc(editor.view.state.selection.main.from, editor.view.state.selection.main.to), 'needle');
    assert.equal(editor.status().mode, 'visual');
    assert.equal(mount.querySelectorAll('.markdown-table').length, 1);
    assert.equal(mount.querySelector('.markdown-table'), tables[1]);
    assert.equal(mount.querySelector('.ot-preview-image'), image); assert.equal(mount.querySelector('.ot-preview-math'), math);
    editor.command('replace');
    const replacement = mount.querySelector<HTMLInputElement>('input[name=replace]')!;
    replacement.value = 'found'; replacement.dispatchEvent(new Event('input', { bubbles: true }));
    mount.querySelector<HTMLButtonElement>('button[name=replace-current]')!.click();
    assert.equal(editor.read(), raw.replace('needle', 'found')); assert.equal(undoDepth(editor.view.state), 1);
    editor.command('undo'); assert.equal(editor.read(), raw);
    editor.command('close-find'); await settleDOM();
    assert.equal(mount.querySelectorAll('.markdown-table').length, 2);
    assert.equal(editor.status().mode, 'visual'); assert.equal(editor.read(), raw);
  } finally { editor.destroy(); mount.remove(); }
});

test('zoom reconfigures the measured theme without changing content, selection or history; reset reports 100 percent', async () => {
  const mount = fixture.mount(), raw = 'first\n\nsecond', editor = new MarkdownEditor(mount, raw, () => {});
  try {
    editor.select(8); const selection = editor.view.state.selection.toJSON(), before = editor.view.themeClasses;
    editor.command('zoom-in'); await settleDOM();
    assert.equal(editor.status().zoom, 1.1); assert.notEqual(editor.view.themeClasses, before);
    assert.equal(getComputedStyle(editor.view.dom).getPropertyValue('--ot-editor-scale'), '1.1');
    assert.equal(editor.read(), raw); assert.deepEqual(editor.view.state.selection.toJSON(), selection); assert.equal(undoDepth(editor.view.state), 0);
    editor.command('zoom-reset'); await settleDOM(); assert.equal(editor.status().zoom, 1);
    assert.equal(getComputedStyle(editor.view.dom).getPropertyValue('--ot-editor-scale'), '1');
  } finally { editor.destroy(); mount.remove(); }
});
