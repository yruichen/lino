import { undoDepth } from '@codemirror/commands';
import { MarkdownEditor } from '../../engine/editor.ts';
import { currentLocale, setLocale, tFor } from '../../localization/index.ts';
import { localeFacet } from '../../localization/editor.ts';
import { changeComposition } from '../source-mode/state.ts';

export async function verifyNavigation(): Promise<{ passed: string[]; failed: string[] }> {
  const passed: string[] = [], failed: string[] = [];
  const check = (name: string, ok: boolean) => (ok ? passed : failed).push(`navigation-${name}`);
  const mount = document.body.appendChild(document.createElement('section'));
  mount.style.cssText = 'position:fixed;left:0;top:0;width:640px;height:420px;z-index:14';
  const raw = '中文👩🏽‍💻\r\nالعربية\n\n| A | B |\r\n| --- | --- |\r\n| C | D |\n\n尾行';
  const editor = new MarkdownEditor(mount, raw, () => {});
  const originalLocale = currentLocale();
  const form = () => mount.querySelector<HTMLFormElement>('.ot-goto-line')!;
  const input = () => form().querySelector<HTMLInputElement>('input')!;
  const submit = (line: string) => {
    input().value = line;
    form().dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
  };
  try {
    editor.setReadOnly(true);
    check('opens-while-readonly', editor.command('goto-line') && !!form());
    check('focuses-line-input', document.activeElement === input());
    submit('0');
    check('invalid-retains-panel-and-selection', input().getAttribute('aria-invalid') === 'true' && editor.view.state.selection.main.head === 0);
    input().value = '2';
    input().dispatchEvent(new InputEvent('input', { bubbles: true, data: '2', inputType: 'insertText' }));
    setLocale('en'); await Promise.resolve();
    check('english-panel-keeps-pending-line', input().value === '2' && input().getAttribute('aria-label') === tFor('en', 'navigation.label'));
    setLocale('zh-Hans'); await Promise.resolve();
    const localized = input().value === '2' && input().getAttribute('aria-label') === tFor('zh-Hans', 'navigation.label');
    check('chinese-panel-keeps-pending-line', localized);
    if (!localized) failed.push(`navigation-locale-state: requested=${currentLocale()}, applied=${editor.view.state.facet(localeFacet)}, label=${input().getAttribute('aria-label')}, value=${input().value}, composing=${editor.composing()}`);
    submit('2');
    check('selects-current-unicode-line', editor.view.state.selection.main.head === editor.view.state.doc.line(2).from && !form());
    check('navigation-does-not-edit', editor.read() === raw && undoDepth(editor.view.state) === 0);
    editor.command('goto-line'); submit('5');
    check('hidden-table-line-reveals-source', editor.snapshot().mode === 'source' && editor.view.state.selection.main.head === editor.view.state.doc.line(5).from);
    editor.command('goto-line');
    editor.view.dispatch({ effects: changeComposition.of(true) });
    const previous = editor.view.state.selection.main.head;
    submit('1');
    check('composition-blocks-submission', editor.view.state.selection.main.head === previous && !!form());
    editor.view.dispatch({ effects: changeComposition.of(false) });
    input().dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    check('escape-closes-without-edit', !form() && editor.read() === raw);
    editor.setReadOnly(false);
    editor.command('goto-line');
    editor.view.dispatch({ changes: { from: editor.view.state.doc.line(2).from, to: editor.view.state.doc.length } });
    const beforeJump = editor.read();
    const historyDepth = undoDepth(editor.view.state);
    submit('5');
    check('edited-document-revalidates-target', !!form() && input().getAttribute('aria-invalid') === 'true');
    submit('2');
    check('current-document-jump-preserves-history', !form() && editor.read() === beforeJump && undoDepth(editor.view.state) === historyDepth);
    editor.command('undo');
    check('undo-still-restores-mixed-source', editor.read() === raw);
  } catch (error) { failed.push(`navigation-exception: ${String(error)}`); }
  finally { editor.destroy(); mount.remove(); setLocale(originalLocale); }
  return { passed, failed };
}
