import { undoDepth } from '@codemirror/commands';
import { MarkdownEditor } from '../../engine/editor.ts';
import { currentLocale, setLocale, tFor } from '../../localization/index.ts';

/** Panel state survives CodeMirror rebuilding panels for localized phrases.
 * This is not acceptance coverage of the unfinished table structure commands. */
export async function verifyTableInsertion(): Promise<{ passed: string[]; failed: string[] }> {
  const passed: string[] = [], failed: string[] = [];
  const check = (name: string, ok: boolean) => (ok ? passed : failed).push(`table-insertion-${name}`);
  const mount = document.body.appendChild(document.createElement('section'));
  mount.style.cssText = 'position:fixed;inset:0;z-index:14';
  const editor = new MarkdownEditor(mount, '', () => {}), originalLocale = currentLocale();
  const panel = () => mount.querySelector<HTMLFormElement>('.ot-table-insert');
  const rows = () => panel()!.querySelector<HTMLInputElement>('input[name=table-rows]')!;
  const columns = () => panel()!.querySelector<HTMLInputElement>('input[name=table-columns]')!;
  try {
    check('opens', editor.command('insert-table') && !!panel());
    rows().value = '7'; rows().dispatchEvent(new Event('input', { bubbles: true }));
    columns().value = '5'; columns().dispatchEvent(new Event('input', { bubbles: true }));
    for (const locale of ['en', 'zh-Hans'] as const) {
      setLocale(locale); await Promise.resolve();
      check(`${locale}-preserves-dimensions`, rows().value === '7' && columns().value === '5'
        && rows().getAttribute('aria-label') === tFor(locale, 'table.rows')
        && columns().getAttribute('aria-label') === tFor(locale, 'table.columns'));
    }
    check('draft-is-not-document-edit', editor.read() === '' && undoDepth(editor.view.state) === 0);
    rows().value = '0'; rows().dispatchEvent(new Event('input', { bubbles: true }));
    panel()!.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    check('invalid-dimensions-retain-panel', !!panel() && !!panel()!.querySelector('output')!.textContent && editor.read() === '');
    setLocale('en'); await Promise.resolve();
    check('locale-preserves-invalid-draft-and-feedback', rows().value === '0' && columns().value === '5'
      && !!panel()!.querySelector('output')!.textContent);
    panel()!.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    editor.command('insert-table');
    check('cancel-reopen-resets-draft', rows().value === '3' && columns().value === '3' && editor.read() === '');
  } catch (error) { failed.push(`table-insertion-exception: ${String(error)}`); }
  finally { editor.destroy(); mount.remove(); setLocale(originalLocale); }
  return { passed, failed };
}
