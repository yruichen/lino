import { EditorView } from '@codemirror/view';
import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { setupDOM, settleDOM } from './dom.mts';
import { undoDepth } from '@codemirror/commands';
import { setLocale } from '../../packages/editor/src/localization/index.ts';
const fixture = setupDOM();
const { MarkdownEditor } = await import('../../packages/editor/src/engine/editor.ts');
after(() => fixture.dom.window.close());

test('language badge adds no editable header row; fences, empty bodies and unclosed blocks retain their source and one body surface', () => {
  for (const [raw, count] of [
    ['```json\n{\n}\n```', 2], ['```text\n\n```', 1], ['```text\n```', 1], ['```rust\nlet a = 1;', 1],
  ] as const) {
    const mount = fixture.mount(), e = new MarkdownEditor(mount, raw, () => {});
    try {
      assert.equal(mount.querySelectorAll('.cm-line').length, count);
      assert.equal(mount.querySelectorAll('.ot-code-first').length, 1);
      assert.equal(mount.querySelectorAll('.ot-code-last').length, 1);
      assert.equal(mount.querySelector('.ot-code-language')!.closest('.cm-line'), null);
      assert(!e.view.contentDOM.textContent!.includes('```'));
      assert.equal(e.read(), raw); assert.equal(undoDepth(e.view.state), 0);
      e.command('source'); assert(e.view.contentDOM.textContent!.includes('```'));
      assert.equal(e.read(), raw); e.command('visual');
      assert.equal(mount.querySelectorAll('.cm-line').length, count);
    } finally { e.destroy(); mount.remove(); }
  }
});

test('code language control changes actual Markdown, preserves a draft across localization and uses the same undo', async () => {
  const mount = fixture.mount(), e = new MarkdownEditor(mount, '```js title\nconst x = 1;\n```', () => {});
  try {
    e.select(e.view.state.doc.toString().indexOf('const'));
    assert.equal(mount.querySelector('.ot-code-tools'), null);
    mount.querySelector<HTMLButtonElement>('.ot-code-language')!.click();
    let input = mount.querySelector<HTMLElement>('[data-code-language-input]')!;
    assert(input); const picker = EditorView.findFromDOM(input)!; picker.focus(); picker.dispatch({ changes: { from: 0, to: picker.state.doc.length, insert: 'python' }, selection: { anchor: 2, head: 4 } });
    assert.equal(getComputedStyle(picker.contentDOM).paddingBottom, '5px');
    assert.equal(getComputedStyle(e.view.contentDOM).paddingBottom, '120px');
    setLocale('zh-Hans'); await settleDOM();
    input = mount.querySelector<HTMLElement>('[data-code-language-input]')!;
    assert.equal(picker.state.doc.toString(), 'python'); assert.equal(e.read(), '```js title\nconst x = 1;\n```');
    assert.equal(document.activeElement, input); assert.equal(picker.state.selection.main.from, 2); assert.equal(picker.state.selection.main.to, 4);
    assert.equal(undoDepth(e.view.state), 0);
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }));
    assert.equal(e.read(), '```python title\nconst x = 1;\n```');
    e.command('source'); assert(e.command('undo')); assert.equal(e.read(), '```js title\nconst x = 1;\n```');
    assert(e.command('redo')); assert.equal(e.read(), '```python title\nconst x = 1;\n```');
  } finally { e.destroy(); mount.remove(); setLocale('en'); }
});
test('code view controls do not change text, and confirmed copy contains neither fences nor displayed line numbers', async () => {
  const mount = fixture.mount(), copied: string[] = [];
  const e = new MarkdownEditor(mount, '```js\nconst x = 1;\n```', () => {}, () => {}, async text => { copied.push(text); });
  try {
    e.select(6); await settleDOM();
    assert(e.command('code-line-numbers')); assert(e.command('code-wrap'));
    assert.equal(e.status().codeNumbers, true); assert.equal(e.status().codeWrap, false);
    assert(mount.querySelector('.ot-code-numbered[data-code-line="1"]'));
    assert(mount.querySelector('.ot-code-nowrap'));
    assert.equal(undoDepth(e.view.state), 0); assert.equal(e.read(), '```js\nconst x = 1;\n```');
    e.command('code-language'); assert(e.command('code-copy')); await settleDOM();
    assert.deepEqual(copied, ['const x = 1;\n']);
    assert(mount.querySelector('.ot-code-tools output')!.textContent!.includes('copied'));
    e.setReadOnly(true); assert(e.command('code-copy')); await settleDOM(); assert.equal(copied.length, 2);
  } finally { e.destroy(); mount.remove(); }
});
test('copy failure is observable, and native indentation cannot edit behind an active language field', async () => {
  const mount = fixture.mount(), e = new MarkdownEditor(mount, '```js\na\n```', () => {}, () => {}, async () => { throw new Error('fixture clipboard failure'); });
  try {
    e.select(6);
    e.command('code-language');
    const input = mount.querySelector<HTMLElement>('[data-code-language-input]')!;
    input.focus(); assert.equal(e.command('code-indent'), false); assert.equal(e.read(), '```js\na\n```');
    assert(e.command('code-copy')); await settleDOM();
    assert(mount.querySelector('.ot-code-tools output')!.textContent!.includes('fixture clipboard failure'));
    const picker = EditorView.findFromDOM(input)!;
    picker.dispatch({ changes: { from: 0, to: picker.state.doc.length, insert: 'bad\nlanguage' } });
    assert.equal(picker.state.doc.toString(), 'js');
    picker.dispatch({ changes: { from: 0, to: picker.state.doc.length, insert: 'bad language' } });
    input.closest('form')!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    assert.equal(e.read(), '```js\na\n```'); assert.equal(undoDepth(e.view.state), 0);
  } finally { e.destroy(); mount.remove(); }
});
