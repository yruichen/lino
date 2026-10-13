import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { undoDepth } from '@codemirror/commands';
import { setupDOM, settleDOM } from './dom.mts';
const fixture = setupDOM();
const { MarkdownEditor } = await import('../../packages/editor/src/engine/editor.ts');
after(() => fixture.dom.window.close());
test('extended inline formatting uses the configured parser, round trips and clears parsed wrappers in one history', () => {
  for (const [command, mark] of [['highlight', '=='], ['superscript', '^'], ['subscript', '~']] as const) {
    const mount = fixture.mount(), editor = new MarkdownEditor(mount, '中文🙂', () => {});
    try {
      editor.select(0, 4); assert(editor.command(command)); assert.equal(editor.read(), `${mark}中文🙂${mark}`);
      assert(editor.command(command)); assert.equal(editor.read(), '中文🙂'); editor.command('undo');
      assert.equal(editor.read(), `${mark}中文🙂${mark}`); editor.command('clear-formatting'); assert.equal(editor.read(), '中文🙂');
    } finally { editor.destroy(); mount.remove(); }
  }
  const raw = '**bold *nested*** and [link](https://example.invalid) with `literal*`', mount = fixture.mount(), editor = new MarkdownEditor(mount, raw, () => {});
  try {
    editor.select(0, raw.length); assert(editor.command('clear-formatting')); assert.equal(editor.read(), 'bold nested and link with literal*');
    assert.equal(undoDepth(editor.view.state), 1); editor.command('undo'); assert.equal(editor.read(), raw);
  } finally { editor.destroy(); mount.remove(); }
});
test('task checkbox and command update only task state, respect readonly/composition and preserve original line endings', async () => {
  const raw = 'before\r\n\r\n- [ ] pending\r\n- [X] done\n', mount = fixture.mount(), editor = new MarkdownEditor(mount, raw, () => {});
  try {
    editor.select(0); await settleDOM();
    const checkbox = mount.querySelector<HTMLInputElement>('input.ot-task-checkbox')!; assert(checkbox); checkbox.checked = true; checkbox.dispatchEvent(new Event('change', { bubbles: true }));
    assert.equal(editor.read(), raw.replace('[ ]', '[x]')); assert.equal(undoDepth(editor.view.state), 1); editor.command('undo'); assert.equal(editor.read(), raw);
    editor.select(editor.view.state.doc.line(3).from, editor.view.state.doc.length); editor.command('toggle-task'); assert.equal(editor.read(), raw.replace('[ ]', '[x]').replace('[X]', '[ ]'));
    editor.command('undo'); assert.equal(editor.read(), raw);
    editor.select(0); editor.setReadOnly(true); await settleDOM(); assert(mount.querySelector<HTMLInputElement>('input.ot-task-checkbox')!.disabled);
    assert.equal(editor.command('toggle-task'), false); assert.equal(editor.read(), raw);
  } finally { editor.destroy(); mount.remove(); }
});
test('front matter and literal code remain protected from structural commands and link-property insertion', () => {
  for (const [raw, position] of [['---\ntitle: demo\n---\n\nbody', 9], ['`literal`', 3], ['```\ncode\n```', 7]] as const) {
    const mount = fixture.mount(), editor = new MarkdownEditor(mount, raw, () => {});
    try { editor.select(position); assert.equal(editor.command('link'), false); assert.equal(editor.read(), raw); assert.equal(undoDepth(editor.view.state), 0); }
    finally { editor.destroy(); mount.remove(); }
  }
});
