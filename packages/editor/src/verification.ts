import { undo, redo } from '@codemirror/commands';
import { changeComposition } from './features/source-mode/state.ts';
import { tablesIn } from './features/tables/model.ts';
import { MarkdownEditor } from './engine/editor.ts';

// Runs in the actual WKWebView DOM, without driving the user's keyboard/IME.
export async function verifyEditor() {
  const passed: string[] = [], failed: string[] = [];
  const mount = document.body.appendChild(document.createElement('section'));
  mount.style.cssText = 'position:fixed;left:0;top:0;width:900px;height:650px;background:white;z-index:10';
  const raw = '# 标题\r\n\r\n**加粗** 与 👩🏽‍💻\n\n| 项目 | 值 |\r\n| --- | --- |\r\n| 中文 | 一 |\r\n\r\n末尾';
  const editor = new MarkdownEditor(mount, raw, () => {});
  const check = (name: string, condition: boolean) => (condition ? passed : failed).push(name);
  const settle = () => new Promise(resolve => setTimeout(resolve, 60));
  try {
    await settle();
    editor.setReadOnly(true);
    check('lifecycle-table-readonly', Array.from(mount.querySelectorAll<HTMLInputElement>('.markdown-table input')).every(input => input.readOnly));
    const frozen = mount.querySelector<HTMLInputElement>('.markdown-table input');
    if (frozen) { frozen.value = '不应提交'; frozen.dispatchEvent(new InputEvent('input', {bubbles: true})); }
    check('lifecycle-table-blocks-stale-input', editor.read() === raw);
    check('lifecycle-structure-command-blocked', !editor.command('add-row'));
    editor.setReadOnly(false);
    check('lifecycle-table-unfreezes', Array.from(mount.querySelectorAll<HTMLInputElement>('.markdown-table input')).every(input => !input.readOnly));
    check('mixed-line-endings-round-trip', editor.snapshot().text === raw);
    editor.select(editor.view.state.doc.length);
    await settle();
    check('inactive-markers-hidden', !editor.view.contentDOM.textContent?.includes('**'));
    const strong = editor.view.state.doc.toString().indexOf('加粗');
    editor.select(strong + 1);
    await settle();
    check('active-markers-revealed', !!editor.view.contentDOM.textContent?.includes('**'));
    const caret = editor.view.coordsAtPos(strong + 1);
    check('caret-coordinate-round-trip', !!caret && editor.view.posAtCoords({ x: caret.left + 1, y: (caret.top + caret.bottom) / 2 }) === strong + 1);
    const selected = JSON.stringify(editor.snapshot().selection);
    editor.command('source');
    check('source-mode-no-document-change', editor.snapshot().text === raw);
    check('source-mode-selection-preserved', JSON.stringify(editor.snapshot().selection) === selected);
    editor.command('visual');
    check('visual-mode-selection-preserved', JSON.stringify(editor.snapshot().selection) === selected);
    const beforeShortcut = editor.read();
    editor.view.contentDOM.dispatchEvent(new KeyboardEvent('keydown', { key: '/', code: 'Slash', metaKey: true, bubbles: true, cancelable: true }));
    check('command-slash-toggles-source-without-comments', editor.snapshot().mode === 'source' && editor.read() === beforeShortcut);
    editor.view.contentDOM.dispatchEvent(new KeyboardEvent('keydown', { key: '/', code: 'Slash', metaKey: true, bubbles: true, cancelable: true }));
    check('command-slash-restores-visual-without-edit', editor.snapshot().mode === 'visual' && editor.read() === beforeShortcut
      && JSON.stringify(editor.snapshot().selection) === selected);
    await settle();
    const input = mount.querySelectorAll<HTMLInputElement>('.markdown-table input')[2];
    check('table-widget-created', !!input);
    if (input) {
      input.focus(); input.value = '已编辑';
      input.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: '已编辑' }));
      await settle();
      check('table-cell-reaches-source', editor.snapshot().text.includes('| 已编辑 | 一 |'));
      check('table-cell-focus-preserved', document.activeElement === input);
      editor.command('source');
      editor.command('undo');
      check('table-undo-across-mode', editor.snapshot().text === raw);
      editor.command('redo');
      check('table-redo-across-mode', editor.snapshot().text.includes('| 已编辑 | 一 |'));
      editor.command('undo');
    }
    editor.command('visual');
    await settle();
    const historyInput = mount.querySelectorAll<HTMLInputElement>('.markdown-table input')[2];
    if (historyInput) {
      historyInput.focus();
      for (const value of ['新', '新内容']) {
        historyInput.value = value;
        historyInput.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: value }));
      }
      historyInput.dispatchEvent(new KeyboardEvent('keydown', { key: 'z', metaKey: true, bubbles: true }));
      check('table-typing-grouped-keyboard-undo', editor.snapshot().text === raw);
    }
    editor.command('visual');
    await settle();
    const compositionInput = mount.querySelectorAll<HTMLInputElement>('.markdown-table input')[2];
    if (compositionInput) {
      compositionInput.focus();
      compositionInput.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
      compositionInput.value = '汉字';
      compositionInput.dispatchEvent(new InputEvent('input', { bubbles: true, isComposing: true, data: '汉字' }));
      check('table-composition-not-committed-early', editor.snapshot().text === raw);
      check('table-composition-mode-deferred', !editor.command('source') && editor.snapshot().mode === 'visual');
      compositionInput.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '汉字' }));
      await settle();
      check('table-composition-committed', editor.snapshot().text.includes('| 汉字 | 一 |'));
      check('table-composition-deferred-mode-applied', editor.snapshot().mode === 'source');
      editor.command('undo');
    }
    const table = tablesIn(editor.view.state.doc.toString())[0];
    editor.select(table.rows[0].cells[0].from);
    editor.command('add-row');
    check('add-row-structure', tablesIn(editor.view.state.doc.toString())[0].rows.length === 2);
    undo(editor.view); check('add-row-undo-exact', editor.snapshot().text === raw);
    redo(editor.view); undo(editor.view);
    editor.command('add-column');
    check('add-column-structure', tablesIn(editor.view.state.doc.toString())[0].header.cells.length === 3);
    undo(editor.view); check('add-column-undo-exact', editor.snapshot().text === raw);
    editor.command('visual');
    editor.select(editor.view.state.doc.length);
    editor.view.focus();
    await settle();
    editor.view.contentDOM.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true }));
    const finalLine = [...editor.view.contentDOM.querySelectorAll<HTMLElement>('.cm-line')].find(line => line.textContent === '末尾');
    check('composition-dom-target-present', !!finalLine);
    if (finalLine) {
      finalLine.textContent = '末尾汉字';
      editor.view.contentDOM.dispatchEvent(new InputEvent('input', { bubbles: true, isComposing: true, data: '汉字' }));
      check('composition-dom-mode-deferred', !editor.command('source'));
      editor.view.contentDOM.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '汉字' }));
      await settle();
      check('composition-dom-text-reaches-engine', editor.snapshot().text === raw + '汉字');
      check('composition-dom-pending-mode-applied', editor.snapshot().mode === 'source');
      editor.command('undo');
      check('composition-dom-undo-restores-source', editor.snapshot().text === raw);
    }
    editor.command('source');
    editor.view.dispatch({ effects: changeComposition.of(true) });
    check('composition-undo-blocked', editor.command('undo') === false);
    editor.command('visual');
    check('composition-mode-still-source', editor.snapshot().mode === 'source');
    editor.view.dispatch({ effects: changeComposition.of(false) });
    await settle();
    check('composition-pending-mode-applied', editor.snapshot().mode === 'visual');
    check('final-raw-content-preserved', editor.snapshot().text === raw);
  } catch (error) { failed.push(String(error)); }
  finally { editor.destroy(); mount.remove(); }
  return { passed, failed, limitation: 'Synthetic composition events validate transaction gating, not a real macOS input method. Native IME, caret geometry, cross-block drag selection and performance still require manual/device verification.' };
}

export async function verifyDocumentEdit(editor: MarkdownEditor): Promise<string> {
  editor.command('visual');
  editor.view.dispatch({ changes: {from: 0, insert: '新🙂\n'} });
  await new Promise(resolve => setTimeout(resolve, 40));
  const inputs = editor.view.dom.querySelectorAll<HTMLInputElement>('.markdown-table input');
  const cell = inputs[3];
  if (!cell) throw new Error('Document fixture table widget missing');
  cell.focus(); cell.value = '二🙂';
  cell.dispatchEvent(new InputEvent('input', {bubbles:true,inputType:'insertText',data:'二🙂'}));
  return editor.read();
}
