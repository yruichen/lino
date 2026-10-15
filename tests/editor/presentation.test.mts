import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { showTooltip } from '@codemirror/view';
import { undoDepth } from '@codemirror/commands';
import { forceParsing } from '@codemirror/language';
import { changeComposition } from '../../packages/editor/src/features/source-mode/state.ts';
import { setupDOM, settleDOM } from './dom.mts';
const fixture = setupDOM();
const { MarkdownEditor } = await import('../../packages/editor/src/engine/editor.ts');
after(() => fixture.dom.window.close());

test('repeated composition keeps heading sizes and surrounding rendered Markdown stable while mapping input', async () => {
  const raw = '# Heading\n\n> Quote\n\n- Bullet\n\n- [ ] Task\n\n---\n\n[label](https://example.com) and [^note]\n\n[^note]: Footnote\n\n[TOC]\n\nbody';
  const mount = fixture.mount(), editor = new MarkdownEditor(mount, raw, () => {});
  try {
    assert(forceParsing(editor.view, editor.view.state.doc.length, 50));
    editor.select(raw.indexOf('Heading') + 'Heading'.length);
    const classes = () => [...mount.querySelectorAll('.cm-line')].map(line => line.className);
    const baseline = classes();
    for (const character of ['甲', '🙂', '乙']) {
      const task = mount.querySelector<HTMLInputElement>('.ot-task-checkbox');
      const rule = mount.querySelector('hr.ot-horizontal-rule');
      const note = mount.querySelector('.ot-footnote-ref');
      const toc = mount.querySelector('.ot-document-toc');
      assert(task && rule && note && toc);
      editor.view.contentDOM.dispatchEvent(new fixture.dom.window.CompositionEvent('compositionstart', { bubbles: true }));
      assert.equal(editor.composing(), true);
      assert.deepEqual(classes(), baseline);
      const from = editor.view.state.selection.main.head;
      editor.view.dispatch({ changes: { from, insert: character }, selection: { anchor: from + character.length }, userEvent: 'input.type.compose' });
      assert.deepEqual(classes(), baseline);
      assert(mount.querySelector('.ot-task-checkbox') === task, 'task DOM survives provisional input');
      assert(mount.querySelector('hr.ot-horizontal-rule') === rule, 'rule DOM survives provisional input');
      assert(mount.querySelector('.ot-footnote-ref') === note, 'footnote DOM survives provisional input');
      assert(mount.querySelector('.ot-document-toc') === toc, 'TOC DOM survives provisional input');
      assert(!editor.view.contentDOM.textContent!.includes('https://example.com'));
      editor.view.contentDOM.dispatchEvent(new fixture.dom.window.CompositionEvent('compositionend', { bubbles: true, data: character }));
      await settleDOM();
      assert.equal(editor.composing(), false);
      assert.deepEqual(classes(), baseline);
      assert.equal(editor.view.state.selection.main.head, from + character.length);
    }
    assert.equal(editor.read(), raw.replace('Heading', 'Heading甲🙂乙'));
    // The checkbox callback must use its new source offset after composition.
    mount.querySelector<HTMLInputElement>('.ot-task-checkbox')!.click();
    assert.equal(editor.read(), raw.replace('Heading', 'Heading甲🙂乙').replace('[ ]', '[x]'));
    assert(editor.command('undo'));
    assert.equal(editor.read(), raw.replace('Heading', 'Heading甲🙂乙'));
  } finally { editor.destroy(); mount.remove(); }
});

test('composition defers new Markdown structure until commit and source mode stays literal', () => {
  const mount = fixture.mount(), editor = new MarkdownEditor(mount, 'title', () => {});
  try {
    editor.view.dispatch({ effects: changeComposition.of(true) });
    editor.view.dispatch({ changes: { from: 0, insert: '# ' }, selection: { anchor: 2 }, userEvent: 'input.type.compose' });
    assert.equal(mount.querySelector('.ot-heading'), null);
    editor.view.dispatch({ effects: changeComposition.of(false) });
    assert(mount.querySelector('.ot-heading-1'));
    editor.command('source');
    editor.view.dispatch({ effects: changeComposition.of(true) });
    assert.equal(mount.querySelector('.ot-heading'), null);
    assert.equal(editor.view.contentDOM.textContent, '# title');
    editor.view.dispatch({ effects: changeComposition.of(false) });
    assert.equal(mount.querySelector('.ot-heading'), null);
  } finally { editor.destroy(); mount.remove(); }
});

test('visual headings, quotes, lists and rules render while source mode and literal code retain their actual text', () => {
  const raw = 'start\n\n# Title\n\n## Subtitle\n\n> Quoted text\n\n- Bullet\n\n---\n\n```text\n# literal\n> literal\n```';
  const mount = fixture.mount(), editor = new MarkdownEditor(mount, raw, () => {});
  try {
    // Parsing is incremental. Complete this small fixture before asserting
    // decorations, rather than depending on the constructor's time slice.
    assert(forceParsing(editor.view, editor.view.state.doc.length, 50));
    assert(mount.querySelector('.ot-heading-1')); assert(mount.querySelector('.ot-heading-2'));
    assert(mount.querySelector('.ot-quote-line')); assert(mount.querySelector('.ot-list-bullet'));
    assert(mount.querySelector('hr.ot-horizontal-rule')); assert(mount.querySelector('.ot-code-first')); assert(mount.querySelector('.ot-code-last'));
    assert.equal(mount.querySelectorAll('.ot-heading').length, 2);
    assert.equal(editor.read(), raw); assert.equal(undoDepth(editor.view.state), 0);
    editor.command('source');
    assert.equal(mount.querySelector('.ot-heading, .ot-quote-line, .ot-horizontal-rule, .ot-code-framed'), null);
    assert.equal(editor.read(), raw); assert(mount.querySelector('.cm-content')!.textContent!.includes('# literal'));
    editor.command('visual'); assert(mount.querySelector('.ot-heading-1'));
  } finally { editor.destroy(); mount.remove(); }
});

test('properties follow their mapped image range, occupy a local tooltip and preserve the draft and document', async () => {
  const raw = 'start\n\n![alt](local.png)\n\nend', mount = fixture.mount(), editor = new MarkdownEditor(mount, raw, () => {});
  try {
    editor.select(raw.indexOf('alt')); editor.command('image-properties');
    const form = mount.querySelector('.ot-media-panel')!;
    assert(form.classList.contains('cm-tooltip')); assert(!form.closest('.cm-panels'));
    assert.equal(editor.view.state.facet(showTooltip).filter(Boolean)[0]!.pos, raw.indexOf('!'));
    const input = form.querySelector<HTMLInputElement>('input[name=image-alt]')!;
    input.value = 'draft'; input.dispatchEvent(new Event('input', { bubbles: true }));
    editor.view.dispatch({ changes: { from: 0, insert: 'prefix\n' } }); await settleDOM();
    assert.equal(editor.view.state.facet(showTooltip).filter(Boolean)[0]!.pos, raw.indexOf('!') + 7);
    assert.equal(mount.querySelector<HTMLInputElement>('input[name=image-alt]')!.value, 'draft');
    assert.equal(editor.read(), 'prefix\n' + raw);
    form.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    assert.equal(mount.querySelector('.ot-media-panel'), null); assert.equal(editor.read(), 'prefix\n' + raw);
  } finally { editor.destroy(); mount.remove(); }
});

test('explicit insertion takes precedence over automatic code tools; Escape dismisses tools without interrupting composition', () => {
  const raw = '```js\nlet x = 1\n```', mount = fixture.mount(), editor = new MarkdownEditor(mount, raw, () => {});
  try {
    editor.select(8); assert.equal(mount.querySelector('.ot-code-tools'), null);
    editor.command('code-language'); assert(mount.querySelector('.ot-code-tools'));
    editor.command('insert-table'); assert(mount.querySelector('.ot-table-insert')); assert.equal(mount.querySelector('.ot-code-tools'), null);
    assert.equal(editor.view.state.facet(showTooltip).filter(Boolean).length, 1);
    mount.querySelector('.ot-table-insert')!.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    editor.command('code-language'); const form = mount.querySelector('.ot-code-tools')!;
    editor.view.dispatch({ effects: changeComposition.of(true) });
    form.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); assert(mount.querySelector('.ot-code-tools'));
    editor.view.dispatch({ effects: changeComposition.of(false) });
    form.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); assert.equal(mount.querySelector('.ot-code-tools'), null);
    assert.equal(editor.read(), raw); assert.equal(undoDepth(editor.view.state), 0);
  } finally { editor.destroy(); mount.remove(); }
});
