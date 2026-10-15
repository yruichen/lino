import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { EditorSelection } from '@codemirror/state';
import { undoDepth } from '@codemirror/commands';
import { codeOptions } from '../../packages/editor/src/features/code/state.ts';
import { setupDOM, settleDOM } from './dom.mts';
const fixture = setupDOM();
const { MarkdownEditor } = await import('../../packages/editor/src/engine/editor.ts');
after(() => fixture.dom.window.close());
const values = { language: 'en', theme: 'dark', theme_family: 'paper', custom_themes: [], body_font: '', background_image: '', background_opacity: 20, surface_opacity: 100, glass_style: 'solid', image_insertion: 'reference', use_theme_font_size: false, use_theme_line_height: false, auto_save: false, font_size: 20, line_height: 180, page_width: 960, content_width: 'fixed',
  spell_check: true, continue_lists: true, code_wrap: false, code_numbers: true };
test('host viewport changes preserve text, selection and history', () => {
  const mount = fixture.mount(), editor = new MarkdownEditor(mount, 'Writing', () => {});
  try {
    editor.view.dispatch({ changes: { from: 7, insert: ' more' }, selection: EditorSelection.cursor(4) });
    const before = editor.snapshot(), history = undoDepth(editor.view.state);
    for (const width of [1080, 811, 970, 1080]) editor.setViewportWidth(width);
    assert.equal(editor.view.dom.style.width, '1080px');
    editor.setViewportWidth(NaN); editor.setViewportWidth(0);
    assert.equal(editor.view.dom.style.width, '1080px');
    assert.deepEqual(editor.snapshot(), before); assert.equal(undoDepth(editor.view.state), history);
  } finally { editor.destroy(); mount.remove(); }
});
test('empty page reuse rejects any undo or redo history even while frozen', () => {
  const mount = fixture.mount(), editor = new MarkdownEditor(mount, '', () => {});
  try {
    editor.setReadOnly(true); assert.equal(editor.canReplaceEmpty(), true); editor.setReadOnly(false);
    editor.view.dispatch({ changes: { from: 0, insert: 'A thought' } });
    assert.equal(editor.canReplaceEmpty(), false);
    editor.command('undo'); assert.equal(editor.read(), '');
    editor.setReadOnly(true); assert.equal(editor.canReplaceEmpty(), false); editor.setReadOnly(false);
    editor.command('redo'); assert.equal(editor.read(), 'A thought');
  } finally { editor.destroy(); mount.remove(); }
});
test('effective preferences change appearance/layout/input projection without editing or resetting history', async () => {
  const mount = fixture.mount(), editor = new MarkdownEditor(mount, '- item\n', () => {});
  try {
    editor.view.dispatch({ changes: { from: editor.view.state.doc.length, insert: 'body' }, selection: EditorSelection.cursor(11) });
    const raw = editor.read(), selection = editor.view.state.selection.toJSON(), history = undoDepth(editor.view.state);
    await editor.applyPreferences(values); await settleDOM();
    assert.equal(getComputedStyle(editor.view.contentDOM).maxWidth, '960px');
    assert.equal(getComputedStyle(editor.view.contentDOM).marginLeft, 'auto');
    assert.equal(getComputedStyle(editor.view.contentDOM).marginRight, 'auto');
    assert.equal(getComputedStyle(editor.view.contentDOM).flexGrow, '0');
    assert.equal(getComputedStyle(editor.view.contentDOM).paddingTop, '32px');
    assert.equal(getComputedStyle(editor.view.scrollDOM).justifyContent, 'center');
    assert.equal(editor.view.dom.dataset.appearance, 'dark');
    assert.equal(editor.view.contentDOM.getAttribute('spellcheck'), 'true');
    assert.deepEqual(editor.view.state.field(codeOptions), { wrap: false, numbers: true });
    assert.equal(editor.read(), raw); assert.deepEqual(editor.view.state.selection.toJSON(), selection); assert.equal(undoDepth(editor.view.state), history);
    await editor.applyPreferences({ ...values, theme: 'light', spell_check: false, content_width: 'adaptive' }); await settleDOM();
    assert.equal(getComputedStyle(editor.view.contentDOM).maxWidth, 'var(--ot-reading-width)');
    assert.equal(getComputedStyle(editor.view.contentDOM).marginLeft, 'auto');
    assert.equal(getComputedStyle(editor.view.contentDOM).marginRight, 'auto');
    assert.equal(editor.view.dom.dataset.appearance, 'light'); assert.equal(editor.view.contentDOM.getAttribute('spellcheck'), 'false');
    editor.command('undo'); assert.equal(editor.read(), '- item\n');
  } finally { editor.destroy(); mount.remove(); }
});
test('list continuation follows the effective preference without changing ordinary Enter or literal code', async () => {
  const mount = fixture.mount(), editor = new MarkdownEditor(mount, '- item', () => {});
  try {
    await editor.applyPreferences(values); editor.select(editor.view.state.doc.length); editor.view.focus();
    editor.view.contentDOM.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true, cancelable: true }));
    assert.equal(editor.read(), '- item\n- '); editor.command('undo');
    await editor.applyPreferences({ ...values, continue_lists: false }); editor.select(editor.view.state.doc.length);
    editor.view.contentDOM.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true, cancelable: true }));
    assert.equal(editor.read(), '- item\n');
  } finally { editor.destroy(); mount.remove(); }
});
test('cancelling a temporary freeze cannot unlock a document lock or change its text/history', () => {
  const mount = fixture.mount(), editor = new MarkdownEditor(mount, 'body', () => {});
  try {
    editor.setDocumentReadOnly(true); editor.setReadOnly(true); editor.setReadOnly(false);
    assert(editor.view.state.readOnly); assert.equal(editor.command('bold'), false); assert.equal(editor.read(), 'body');
    assert.equal(undoDepth(editor.view.state), 0);
    editor.setDocumentReadOnly(false); editor.select(0, 4); assert(editor.command('bold')); assert.equal(editor.read(), '**body**');
  } finally { editor.destroy(); mount.remove(); }
});

test('theme families, both appearances and a DIY palette keep the same writing session and explicit typography', async () => {
  const { builtinThemes } = await import('../../packages/editor/src/themes/catalog.ts');
  const mount = fixture.mount(), editor = new MarkdownEditor(mount, '# Heading\n\nA paragraph.\n', () => {});
  try {
    editor.view.dispatch({ changes: { from: editor.view.state.doc.length, insert: 'More.' }, selection: EditorSelection.cursor(14) });
    const raw = editor.read(), selection = editor.view.state.selection.toJSON(), history = undoDepth(editor.view.state);
    for (const family of builtinThemes) for (const appearance of ['light', 'dark']) {
      await editor.applyPreferences({ ...values, theme: appearance, theme_family: family.id, use_theme_font_size: true, use_theme_line_height: true }); await settleDOM();
      assert.equal(editor.view.dom.style.getPropertyValue('--ot-background'), (appearance === 'dark' ? family.dark : family.light).colors.bg);
      assert.equal(editor.view.dom.style.getPropertyValue('--ot-reading-width'), `max(${family.reading_width}px, 61.80339887498948%)`);
      assert.equal(editor.read(), raw); assert.deepEqual(editor.view.state.selection.toJSON(), selection); assert.equal(undoDepth(editor.view.state), history);
    }
    const custom = structuredClone(builtinThemes[0]); custom.id = 'custom-writing'; custom.name = 'Writing'; custom.dark.colors.bg = '#123456';
    await editor.applyPreferences({ ...values, theme_family: custom.id, custom_themes: [custom], body_font: 'Georgia' }); await settleDOM();
    assert.equal(editor.view.dom.style.getPropertyValue('--ot-background'), '#123456');
    assert.equal(getComputedStyle(editor.view.contentDOM).fontFamily.startsWith('"Georgia"'), true);
    assert.equal(getComputedStyle(editor.view.contentDOM).lineHeight, '1.8');
    assert.equal(editor.read(), raw); assert.deepEqual(editor.view.state.selection.toJSON(), selection); assert.equal(undoDepth(editor.view.state), history);
    editor.command('undo'); assert.equal(editor.read(), '# Heading\n\nA paragraph.\n');
  } finally { editor.destroy(); mount.remove(); }
});

test('page backdrop follows the active editor palette and appearance', async () => {
  const mount = fixture.mount(); mount.id = 'editor';
  const editor = new MarkdownEditor(mount, 'Writing', () => {});
  try {
    await editor.applyPreferences({ ...values, theme_family: 'grove', theme: 'light' }); await settleDOM();
    const page = mount.ownerDocument.documentElement;
    assert.equal(page.style.getPropertyValue('--ot-background'), editor.view.dom.style.getPropertyValue('--ot-background'));
    assert.equal(page.style.colorScheme, 'light');
    await editor.applyPreferences({ ...values, theme_family: 'grove', theme: 'dark' }); await settleDOM();
    assert.equal(page.style.getPropertyValue('--ot-background'), editor.view.dom.style.getPropertyValue('--ot-background'));
    assert.equal(page.style.colorScheme, 'dark'); assert.equal(editor.read(), 'Writing');
  } finally { editor.destroy(); mount.remove(); }
});
