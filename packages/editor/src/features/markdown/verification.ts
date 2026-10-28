import { MarkdownEditor } from '../../engine/editor.ts';
import { changeComposition } from '../source-mode/state.ts';
import { t } from '../../localization/index.ts';

export async function verifyMarkdown(): Promise<{ passed: string[]; failed: string[] }> {
  const passed: string[] = [], failed: string[] = [], errors: string[] = [];
  const check = (name: string, ok: boolean) => (ok ? passed : failed).push(`format-${name}`);
  const mount = document.body.appendChild(document.createElement('section'));
  mount.style.cssText = 'position:fixed;left:0;top:0;width:900px;height:650px;background:white;z-index:14';
  const raw = '中文🙂\r\n第二行\n\n末尾';
  const editor = new MarkdownEditor(mount, raw, event => { if (event.kind === 'error') errors.push(event.message); });
  try {
    editor.select(0, 4);
    check('bold-command', editor.command('bold') && editor.read() === '**中文🙂**\r\n第二行\n\n末尾');
    editor.command('source'); editor.command('undo');
    check('mode-crossing-undo', editor.read() === raw);
    editor.select(0, 4);
    check('italic-command', editor.command('italic') && editor.read().startsWith('*中文🙂*'));
    editor.command('undo'); editor.select(0, 4);
    check('strike-command', editor.command('strikethrough') && editor.read().startsWith('~~中文🙂~~'));
    editor.command('undo'); editor.select(0, 4);
    check('inline-code-command', editor.command('inline-code') && editor.read().startsWith('`中文🙂`'));
    editor.command('undo'); editor.select(0, 4);
    const linkOpened = editor.command('link');
    const linkPanel = mount.querySelector<HTMLFormElement>('.ot-reference-tools');
    check('link-command-opens-properties', linkOpened && !!linkPanel);
    const linkURL = linkPanel?.querySelector<HTMLInputElement>('input[name=link-url]');
    if (linkURL && linkPanel) {
      linkURL.value = 'https://example.com';
      linkURL.dispatchEvent(new InputEvent('input', { bubbles: true }));
      linkPanel.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    }
    check('link-properties-apply', editor.read().startsWith('[中文🙂](<https://example.com>)'));
    editor.command('undo'); editor.select(1);
    check('heading-command', editor.command('heading-3') && editor.read().startsWith('### 中文🙂'));
    editor.command('undo'); editor.select(0, editor.view.state.doc.line(3).from);
    check('ordered-list-command', editor.command('ordered-list') && editor.read().startsWith('1. 中文🙂\r\n2. 第二行'));
    editor.command('task-list'); check('task-list-conversion', editor.read().startsWith('- [ ] 中文🙂\r\n- [ ] 第二行'));
    editor.command('undo'); editor.command('undo'); check('lists-undo-exact', editor.read() === raw);
    editor.select(0, editor.view.state.doc.line(3).from);
    check('blockquote-command', editor.command('blockquote') && editor.read().startsWith('> 中文🙂\r\n> 第二行'));
    editor.command('undo'); editor.select(0, editor.view.state.doc.line(3).from);
    check('code-block-command', editor.command('code-block') && editor.read().startsWith('```\r\n中文🙂\r\n第二行\r\n```'));
    check('code-block-toggle-no-extra-newline', editor.command('code-block') && editor.read() === raw);
    editor.command('undo'); editor.command('undo'); check('code-block-undo-exact', editor.read() === raw);
    editor.setReadOnly(true);
    check('readonly-rejects', !editor.command('bold') && !editor.command('bullet-list') && editor.read() === raw);
    editor.setReadOnly(false); editor.view.dispatch({ effects: changeComposition.of(true) });
    check('composition-rejects', !editor.command('italic') && !editor.command('heading-1') && editor.read() === raw);
    editor.view.dispatch({ effects: changeComposition.of(false) });
    editor.select(0, editor.view.state.doc.line(3).from);
    check('multiline-inline-code-reports-error', !editor.command('inline-code') && errors.at(-1) === t('format.codeLine') && editor.read() === raw);
    editor.command('visual'); check('final-content-exact', editor.read() === raw);
  } catch (error) { failed.push(`format-exception: ${String(error)}`); }
  finally { editor.destroy(); mount.remove(); }
  const input = await verifyFormattingInput();
  passed.push(...input.passed); failed.push(...input.failed);
  return { passed, failed };
}

/** Exercise WebKit's editable DOM and CM's DOM observer without resetting the
 * selection between keystrokes: doing so would hide reversed-input regressions. */
async function verifyFormattingInput(): Promise<{ passed: string[]; failed: string[] }> {
  const passed: string[] = [], failed: string[] = [];
  const cases = [
    { name: 'empty-heading', text: '', at: 0, command: 'heading-3', prefix: '### ', tail: '' },
    { name: 'blank-line-heading', text: '上文\r\n\r\n下文', at: 3, command: 'heading-2', prefix: '上文\r\n## ', tail: '\r\n下文' },
    { name: 'emoji-heading', text: '🙂正文', at: 0, command: 'heading-1', prefix: '# ', tail: '🙂正文' },
    { name: 'empty-list', text: '', at: 0, command: 'bullet-list', prefix: '- ', tail: '' },
    { name: 'empty-quote', text: '', at: 0, command: 'blockquote', prefix: '> ', tail: '' },
    { name: 'empty-code-block', text: '', at: 0, command: 'code-block', prefix: '```\n', tail: '\n```' },
  ] as const;
  for (const fixture of cases) {
    const mount = document.body.appendChild(document.createElement('section'));
    mount.style.cssText = 'position:fixed;inset:0;z-index:14';
    const editor = new MarkdownEditor(mount, fixture.text, () => {});
    try {
      editor.select(fixture.at);
      const accepted = editor.command(fixture.command);
      let typed = '', ok = accepted;
      let head = fixture.prefix.replace(/\r\n/g, '\n').length;
      const caretMatches = () => {
        const selection = document.getSelection();
        return editor.view.state.selection.main.empty && editor.view.state.selection.main.head === head
          && selection?.isCollapsed === true && selection.focusNode !== null
          && editor.view.contentDOM.contains(selection.focusNode)
          && editor.view.posAtDOM(selection.focusNode, selection.focusOffset) === head;
      };
      ok = ok && caretMatches();
      for (const character of ['甲', '🙂', '乙']) {
        ok = document.execCommand('insertText', false, character) && ok;
        await new Promise(resolve => setTimeout(resolve, 30));
        typed += character; head += character.length;
        ok = ok && editor.read() === fixture.prefix + typed + fixture.tail && caretMatches();
      }
      (ok ? passed : failed).push(`format-dom-typing-${fixture.name}`);
    } catch (error) { failed.push(`format-dom-typing-${fixture.name}: ${String(error)}`); }
    finally { editor.destroy(); mount.remove(); }
  }
  return { passed, failed };
}
