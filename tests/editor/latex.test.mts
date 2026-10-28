import assert from 'node:assert/strict';
import { test } from 'node:test';
import { setupDOM } from './dom.mts';
import { LatexEditor } from '../../packages/editor/src/profiles/latex.ts';

const fixture = setupDOM();

test('LaTeX profile edits source without Markdown presentation or newline loss', () => {
  const raw = '\\documentclass{article}\r\n\\begin{document}\r\n中文\r\n\\end{document}\r\n';
  const mount = fixture.mount();
  const editor = new LatexEditor(mount, raw, () => {});
  try {
    assert.equal(editor.read(), raw);
    assert.equal(editor.status().mode, 'source');
    assert.equal(editor.status().changedFromInitial, false);
    editor.view.dispatch({ changes: { from: 0, insert: '% draft\n' } });
    assert.equal(editor.read(), '% draft\r\n' + raw);
    assert.equal(editor.status().changedFromInitial, true);
    editor.setReadOnly(true);
    assert.equal(editor.command('bold'), false);
    assert.equal(editor.read(), '% draft\r\n' + raw);
  } finally {
    editor.destroy();
    mount.remove();
  }
});
