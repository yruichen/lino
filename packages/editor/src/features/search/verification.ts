import { MarkdownEditor } from '../../engine/editor.ts';
import { changeComposition } from '../source-mode/state.ts';
import { tFor } from '../../localization/index.ts';
import { localeFacet } from '../../localization/editor.ts';

// Isolated DOM fixture for the application's real WKWebView verification run.
export async function verifySearch(): Promise<{ passed: string[]; failed: string[] }> {
  const passed: string[] = [], failed: string[] = [];
  const check = (name: string, ok: boolean) => (ok ? passed : failed).push(`search-${name}`);
  const mount = document.body.appendChild(document.createElement('section'));
  mount.style.cssText = 'position:fixed;left:0;top:0;width:900px;height:650px;background:white;z-index:12';
  const raw = 'cat Cat scatter\r\n中文🙂\n\n| A | B |\r\n| --- | --- |\r\n| cat | dog |';
  const editor = new MarkdownEditor(mount, raw, () => {});
  const input = (name: string) => mount.querySelector<HTMLInputElement>(`.ot-search input[name="${name}"]`)!;
  const button = (name: string) => mount.querySelector<HTMLButtonElement>(`.ot-search button[name="${name}"]`)!;
  const set = (name: string, value: string) => { input(name).value = value; input(name).dispatchEvent(new InputEvent('input', { bubbles: true })); };
  const option = (name: string, checked: boolean) => { input(name).checked = checked; input(name).dispatchEvent(new Event('change', { bubbles: true })); };
  const count = () => mount.querySelector('output')?.textContent ?? '';
  const settle = () => new Promise(resolve => setTimeout(resolve, 25));
  try {
    await settle();
    check('table-visible-before-find', !!mount.querySelector('.markdown-table'));
    check('command-opens-panel', editor.command('find') && !!mount.querySelector('.ot-search'));
    check('find-focus', document.activeElement === input('search'));
    check('table-stays-rendered-while-searching', !!mount.querySelector('.markdown-table') && editor.snapshot().mode === 'visual');
    set('search', 'cat');
    check('match-count', count() === tFor(editor.view.state.facet(localeFacet), 'search.matches', {count: 4}));
    option('case', true); option('word', true);
    check('case-word-count', count() === tFor(editor.view.state.facet(localeFacet), 'search.matches', {count: 2}));
    editor.command('find-next');
    check('next-selects-first', editor.view.state.selection.main.from === 0 && editor.view.state.selection.main.to === 3);
    input('search').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
    check('enter-next-selects-table-match', editor.view.state.selection.main.from === editor.view.state.doc.toString().lastIndexOf('cat'));
    input('search').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', shiftKey: true, bubbles: true }));
    check('shift-enter-previous', editor.view.state.selection.main.from === 0);
    editor.command('replace'); set('replace', 'dog');
    check('replace-row-visible', !input('replace').parentElement!.hidden);
    button('replace-current').click();
    check('replace-current-content', editor.read() === raw.replace(/^cat/, 'dog'));
    editor.command('undo'); check('replace-current-undo', editor.read() === raw);
    set('search', 'cat'); button('replace-all').click();
    check('replace-all-shared-document', editor.read() === raw.replace(/^cat/, 'dog').replace('| cat |', '| dog |'));
    editor.command('undo'); check('replace-all-single-undo', editor.read() === raw);
    editor.setReadOnly(true);
    check('readonly-controls-disabled', button('replace-all').disabled && input('replace').disabled);
    button('replace-all').click(); check('readonly-content-preserved', editor.read() === raw);
    editor.setReadOnly(false);
    editor.view.dispatch({ effects: changeComposition.of(true) });
    check('composition-replace-disabled', button('replace-all').disabled && !editor.command('find-next'));
    editor.view.dispatch({ effects: changeComposition.of(false) });
    option('regexp', true); set('search', '[');
    check('invalid-regex-feedback', count() === tFor(editor.view.state.facet(localeFacet), 'search.invalid') && input('search').getAttribute('aria-invalid') === 'true' && button('replace-all').disabled);
    set('search', 'cat'); option('regexp', false);
    input('search').dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    await settle();
    check('escape-closes-panel', !mount.querySelector('.ot-search'));
    check('close-restores-table', !!mount.querySelector('.markdown-table') && editor.snapshot().mode === 'visual');
    check('close-preserves-content', editor.read() === raw);
  } catch (error) { failed.push(`search-exception: ${String(error)}`); }
  finally { editor.destroy(); mount.remove(); }
  return { passed, failed };
}
