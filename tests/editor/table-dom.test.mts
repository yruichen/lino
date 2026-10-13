import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { setupDOM, settleDOM } from './dom.mts';
const fixture = setupDOM();
const { MarkdownEditor } = await import('../../packages/editor/src/engine/editor.ts');
after(() => fixture.dom.window.close());
const raw = '| A | B |\n| --- | --- |\n| x | y |\n| 中 | 👩🏽‍💻 |';
test('moving rows/columns updates active cell contents, transfers focus and undo/redo restore coherent cells', async () => {
  const mount = fixture.mount(), e = new MarkdownEditor(mount, raw, () => {});
  const cell = (row: number, column: number) => mount.querySelector<HTMLInputElement>(`input[data-row="${row}"][data-column="${column}"]`)!;
  const run = (command: Parameters<typeof e.command>[0]) => { assert(e.command(command)); };
  try {
    await settleDOM(); cell(1, 0).focus(); run('move-row-down'); await settleDOM();
    assert.equal(cell(1, 0).value, '中'); assert.equal(cell(2, 0).value, 'x'); assert.equal(document.activeElement, cell(2, 0));
    run('move-column-right'); await settleDOM();
    assert.equal(cell(2, 0).value, 'y'); assert.equal(cell(2, 1).value, 'x'); assert.equal(document.activeElement, cell(2, 1));
    assert(e.command('undo')); await settleDOM();
    assert.equal(cell(2, 0).value, 'x'); assert.equal(document.activeElement, cell(2, 0));
    assert(e.command('undo')); await settleDOM(); assert.equal(e.read(), raw); assert.equal(document.activeElement, cell(1, 0));
    assert(e.command('redo')); await settleDOM(); assert.equal(cell(1, 0).value, '中');
    e.command('source'); e.command('visual'); await settleDOM(); assert.equal(document.activeElement, cell(2, 0));
  } finally { e.destroy(); mount.remove(); }
});
test('Tab reaches the next cell and appends one row at the final cell; Shift-Tab returns without changing content', async () => {
  const mount = fixture.mount(), e = new MarkdownEditor(mount, raw, () => {});
  const cell = (row: number, column: number) => mount.querySelector<HTMLInputElement>(`input[data-row="${row}"][data-column="${column}"]`)!;
  try {
    await settleDOM(); cell(1, 0).focus(); cell(1, 0).dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', bubbles: true, cancelable: true }));
    assert.equal(document.activeElement, cell(1, 1));
    cell(1, 1).dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', shiftKey: true, bubbles: true, cancelable: true }));
    assert.equal(document.activeElement, cell(1, 0)); assert.equal(e.read(), raw);
    cell(2, 1).focus(); cell(2, 1).dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', bubbles: true, cancelable: true })); await settleDOM();
    assert(cell(3, 0)); assert.equal(document.activeElement, cell(3, 0));
    assert(e.command('undo')); await settleDOM(); assert.equal(e.read(), raw); assert.equal(document.activeElement, cell(2, 1));
  } finally { e.destroy(); mount.remove(); }
});
