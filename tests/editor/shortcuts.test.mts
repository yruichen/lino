import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { editorCommands, markdownShortcuts } from '../../packages/protocol/src/client/editor-host.ts';
import { setupDOM } from './dom.mts';
const fixture = setupDOM();
Object.defineProperty(fixture.dom.window.navigator, 'platform', { value: 'MacIntel' });
const { MarkdownEditor } = await import('../../packages/editor/src/engine/editor.ts');
const { formatCommands } = await import('../../packages/editor/src/features/markdown/commands.ts');
const { changeComposition } = await import('../../packages/editor/src/features/source-mode/state.ts');
after(() => fixture.dom.window.close());

function press(editor: InstanceType<typeof MarkdownEditor>, command: string) {
  const binding = markdownShortcuts.find(binding => binding.command === command)!;
  const key = binding.modifiers.includes('shift') && /^[a-z]$/.test(binding.key) ? binding.key.toUpperCase() : binding.key;
  editor.view.contentDOM.dispatchEvent(new KeyboardEvent('keydown', { key,
    keyCode: /^[a-z0-9]$/.test(binding.key) ? binding.key.toUpperCase().charCodeAt(0) : 0,
    metaKey: binding.modifiers.includes('command'), shiftKey: binding.modifiers.includes('shift'),
    altKey: binding.modifiers.includes('option'), ctrlKey: binding.modifiers.includes('control'), bubbles: true, cancelable: true }));
}
test('the shared shortcut registry covers Markdown formatting and has no duplicate bindings or unknown commands', () => {
  const keys = markdownShortcuts.map(binding => [...binding.modifiers].sort().join('+') + '+' + binding.key);
  assert.equal(new Set(keys).size, keys.length);
  for (const binding of markdownShortcuts) assert((editorCommands as readonly string[]).includes(binding.command));
  for (const command of formatCommands) assert(markdownShortcuts.some(binding => binding.command === command), command);
});
test('Cmd 1–6 apply headings in both modes; Cmd 0 restores a paragraph and undo keeps Unicode and line endings', () => {
  for (const mode of ['visual', 'source'] as const) for (let level = 1; level <= 6; level++) {
    const mount = fixture.mount(), raw = '中文🙂\r\n\r\n尾行', editor = new MarkdownEditor(mount, raw, () => {});
    try {
      editor.command(mode); editor.select(2); editor.view.focus();
      press(editor, `heading-${level}`);
      assert.equal(editor.read(), '#'.repeat(level) + ' ' + raw); assert.equal(editor.status().mode, mode);
      press(editor, 'paragraph'); assert.equal(editor.read(), raw);
      assert(editor.command('undo')); assert.equal(editor.read(), '#'.repeat(level) + ' ' + raw);
      assert(editor.command('undo')); assert.equal(editor.read(), raw);
    } finally { editor.destroy(); mount.remove(); }
  }
});
test('inline, list and block shortcuts execute the real editing commands through the same undo history', () => {
  for (const [command, raw, expected] of [
    ['bold', 'body', '**body**'], ['italic', 'body', '*body*'], ['strikethrough', 'body', '~~body~~'],
    ['inline-code', 'body', '`body`'], ['highlight', 'body', '==body=='],
    ['bullet-list', 'body', '- body'], ['ordered-list', 'body', '1. body'],
    ['task-list', 'body', '- [ ] body'], ['blockquote', 'body', '> body'],
    ['code-block', 'body', '```\nbody\n```'],
  ]) {
    const mount = fixture.mount(), editor = new MarkdownEditor(mount, raw, () => {});
    try { editor.select(0, raw.length); editor.view.focus(); press(editor, command); assert.equal(editor.read(), expected, command); assert(editor.command('undo')); assert.equal(editor.read(), raw); }
    finally { editor.destroy(); mount.remove(); }
  }
});
test('format shortcuts respect read-only, composition and focused form inputs', () => {
  const mount = fixture.mount(), editor = new MarkdownEditor(mount, 'body', () => {});
  try {
    editor.view.focus(); editor.setReadOnly(true); press(editor, 'heading-1'); assert.equal(editor.read(), 'body');
    editor.setReadOnly(false); editor.view.dispatch({ effects: changeComposition.of(true) }); press(editor, 'bold'); assert.equal(editor.read(), 'body');
    editor.view.dispatch({ effects: changeComposition.of(false) });
    const input = editor.view.dom.appendChild(document.createElement('input')); input.focus();
    assert.equal(editor.command('bold'), false); assert.equal(document.activeElement, input); assert.equal(editor.read(), 'body');
  } finally { editor.destroy(); mount.remove(); }
});

test('paragraph shortcut removes ATX closing marks and Setext underlines without losing containers', () => {
  for (const [raw, expected] of [['# 中文 ###\r\n\r\nTail', '中文\r\n\r\nTail'], ['Title\n---', 'Title'], ['> ## 标题 ##\n> next', '> 标题\n> next'], ['- ## 标题 ##\n- next', '- 标题\n- next']]) {
    const mount = fixture.mount(), editor = new MarkdownEditor(mount, raw, () => {});
    try { editor.select(raw.indexOf(raw.includes('标题') ? '标题' : raw.includes('中文') ? '中文' : 'Title')); editor.view.focus(); press(editor, 'paragraph'); assert.equal(editor.read(), expected); editor.command('undo'); assert.equal(editor.read(), raw); }
    finally { editor.destroy(); mount.remove(); }
  }
});
