import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { EditorSelection } from '@codemirror/state';
import { undoDepth } from '@codemirror/commands';
import { codeOptions } from '../../packages/editor/src/features/code/state.ts';
import { setupDOM, settleDOM } from './dom.mts';
const fixture = setupDOM();
const { MarkdownEditor } = await import('../../packages/editor/src/engine/editor.ts');
after(() => fixture.dom.window.close());
const values = { language: 'en', theme: 'dark', auto_save: false, font_size: 20, line_height: 180, page_width: 960, content_width: 'fixed',
  spell_check: true, continue_lists: true, code_wrap: false, code_numbers: true };
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
