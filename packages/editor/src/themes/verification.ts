import { Compartment, EditorSelection, EditorState } from '@codemirror/state';
import { history, undo, undoDepth } from '@codemirror/commands';
import { markdown } from '@codemirror/lang-markdown';
import { EditorView } from '@codemirror/view';
import { themeConfiguration } from './editor.ts';
import { MarkdownEditor } from '../engine/editor.ts';

function contrast(a: string, b: string): number {
  const luminance = (color: string) => {
    const rgb = color.match(/[\d.]+/g)?.slice(0, 3).map(Number);
    if (!rgb || rgb.length !== 3) return NaN;
    const linear = rgb.map(value => value / 255 <= .04045 ? value / 255 / 12.92 : ((value / 255 + .055) / 1.055) ** 2.4);
    return .2126 * linear[0]! + .7152 * linear[1]! + .0722 * linear[2]!;
  };
  const values = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (values[0]! + .05) / (values[1]! + .05);
}

export async function verifyTheme(): Promise<{ passed: string[]; failed: string[] }> {
  const passed: string[] = [], failed: string[] = [];
  const check = (name: string, ok: boolean) => (ok ? passed : failed).push(`theme-${name}`);
  const mount = document.body.appendChild(document.createElement('section'));
  mount.style.cssText = 'position:fixed;inset:0;z-index:15';
  const actual = new MarkdownEditor(mount, '', () => {});
  check('engine-initial-system-appearance', actual.view.state.facet(EditorView.darkTheme) === matchMedia('(prefers-color-scheme: dark)').matches);
  actual.destroy();
  const appearance = new Compartment();
  const view = new EditorView({ parent: mount, state: EditorState.create({ doc: '# 标题\n正文', extensions: [
    history(), markdown(), appearance.of(themeConfiguration(false)),
  ] }) });
  const panel = view.dom.appendChild(document.createElement('section'));
  panel.className = 'cm-panel ot-search';
  const input = panel.appendChild(document.createElement('input'));
  input.className = 'ot-search-input'; input.value = '查找';
  const button = panel.appendChild(document.createElement('button')); button.textContent = '下一项';
  try {
    view.dispatch({ changes: { from: view.state.doc.length, insert: '🙂' }, selection: EditorSelection.cursor(9) });
    const text = view.state.doc.toString(), selection = view.state.selection, depth = undoDepth(view.state);
    const colors: string[] = [];
    for (const dark of [false, true, false]) {
      view.dispatch({ effects: appearance.reconfigure(themeConfiguration(dark)) });
      view.focus();
      // Computed style forces style resolution even in a hidden native fixture;
      // requestAnimationFrame may never fire for an off-screen WKWebView.
      const surface = getComputedStyle(view.dom), content = getComputedStyle(view.contentDOM);
      const heading = view.contentDOM.querySelector('.cm-line span');
      colors.push(content.caretColor);
      check(`${dark ? 'dark' : 'light'}-caret-and-text`, view.state.facet(EditorView.darkTheme) === dark
        && contrast(content.caretColor, surface.backgroundColor) >= 4.5
        && contrast(content.color, surface.backgroundColor) >= 4.5);
      check(`${dark ? 'dark' : 'light'}-heading-contrast`, !!heading
        && contrast(getComputedStyle(heading).color, surface.backgroundColor) >= 4.5);
      check(`${dark ? 'dark' : 'light'}-panel-input-button-contrast`, [panel, input, button].every(element => {
        const style = getComputedStyle(element);
        return contrast(style.color, style.backgroundColor) >= 4.5;
      }));
      check(`${dark ? 'dark' : 'light'}-preserves-edit-state`, view.state.doc.toString() === text
        && view.state.selection.eq(selection) && undoDepth(view.state) === depth);
    }
    check('appearance-changes-native-caret-color', colors[0] !== colors[1] && colors[0] === colors[2]);
    check('undo-after-appearance-change', undo(view) && view.state.doc.toString() === '# 标题\n正文');
  } catch (error) { failed.push(`theme-exception: ${String(error)}`); }
  finally { view.destroy(); mount.remove(); }
  return { passed, failed };
}
