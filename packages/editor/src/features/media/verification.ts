import { EditorView } from '@codemirror/view';
import { undoDepth } from '@codemirror/commands';
import { MarkdownEditor } from '../../engine/editor.ts';

/** Real WebKit geometry; synthetic documents only, no native input or focus. */
export async function verifyMediaLayout(captureCode?: () => Promise<void>) {
  const passed: string[] = [], failed: string[] = [];
  let scroll: { before: number; after: number; layoutBefore: unknown; layoutAfter: unknown } | undefined;
  const check = (name: string, value: boolean) => (value ? passed : failed).push(name);
  // Hidden WKWebViews may suspend animation frames. A public coordinate read
  // flushes CM's pending measurement, as a normal visible frame would.
  const frame = () => new Promise<void>(resolve => setTimeout(() => {
    editor.view.coordsAtPos(editor.view.viewport.from); resolve();
  }, 40));
  const wait = async (name: string, condition: () => boolean) => {
    const end = Date.now() + 5000;
    while (!condition() && Date.now() < end) await frame();
    if (!condition()) throw new Error(`Media layout fixture did not settle: ${name}; viewport=${JSON.stringify(editor.view.viewport)}; previews=${[...mount.querySelectorAll('.ot-preview')].map(node => node.textContent?.slice(0,80)).join('|')}`);
  };
  const mount = document.body.appendChild(document.createElement('section'));
  mount.style.cssText = 'position:fixed;inset:0;background:var(--ot-background);z-index:10';
  let editor = new MarkdownEditor(mount, '```swift\nlet message = "hello"\n```', () => {});
  try {
    await frame(); await frame();
    mount.querySelector<HTMLButtonElement>('.ot-code-language')!.click();
    await frame(); await frame();
    const panel = mount.querySelector<HTMLElement>('.ot-code-tools')!;
    const input = panel.querySelector<HTMLElement>('[data-code-language-input]')!;
    check('code-picker-is-one-compact-row-without-document-padding', panel.getBoundingClientRect().height <= 48
      && panel.getBoundingClientRect().width <= 224 && getComputedStyle(input).paddingBottom === '5px');
    check('code-picker-does-not-open-an-unfiltered-catalogue', !mount.querySelector('.cm-tooltip-autocomplete'));
    await captureCode?.();
    const picker = EditorView.findFromDOM(input)!;
    picker.dispatch({ changes: { from: 0, to: picker.state.doc.length, insert: 'py' }, selection: { anchor: 2 }, userEvent: 'input.type' });
    await wait('language suggestions', () => !!mount.querySelector('.cm-tooltip-autocomplete li'));
    check('code-picker-suggests-python-while-typing', [...mount.querySelectorAll('.cm-tooltip-autocomplete li')].some(node => node.textContent?.includes('Python')));
    editor.destroy(); mount.replaceChildren();

    // Observe the first DOM insertion while moving up from the bottom. Math
    // must already have real markup, including a formula never visited before.
    editor = new MarkdownEditor(mount, 'prime\n\n$$\n\\frac{x}{\\sqrt{1+y^2}}\n$$\n', () => {});
    await wait('initial formula', () => !!mount.querySelector('.ot-preview[data-preview-state=ready]'));
    await document.fonts.ready;
    editor.destroy(); mount.replaceChildren();
    const raw = Array.from({ length: 80 }, (_, index) => `$$\n\\frac{x_{${index}}}{\\sqrt{1+y^2}}\n$$\n\nAnchor ${index}\n\n${'A paragraph for scrolling. '.repeat(24)}\n\n`).join('');
    let placeholders = 0, inserted = 0;
    const observer = new MutationObserver(records => {
      for (const record of records) for (const node of record.addedNodes) if (node instanceof Element) {
        const roots = node.matches('.ot-preview-math') ? [node] : [...node.querySelectorAll('.ot-preview-math')];
        for (const root of roots) { inserted++; if (root.getAttribute('data-preview-state') !== 'ready') placeholders++; }
      }
    });
    observer.observe(mount, { childList: true, subtree: true });
    try {
      editor = new MarkdownEditor(mount, raw, () => {});
      const view = editor.view, anchor = raw.indexOf('Anchor 40');
      const layout = () => ({ top: view.scrollDOM.scrollTop, height: view.contentHeight, block: view.lineBlockAt(anchor), viewport: view.viewport,
        domTop: view.documentTop, formulas: [...mount.querySelectorAll('.ot-preview-math')].map(node => ({ from: node.getAttribute('data-preview-from'), height: node.getBoundingClientRect().height })) });
      view.dispatch({ effects: EditorView.scrollIntoView(view.state.doc.length, { y: 'end' }) });
      await frame(); await frame();
      check('formula-fixture-starts-at-the-document-bottom', view.viewport.from > anchor);
      view.dispatch({ effects: EditorView.scrollIntoView(raw.indexOf('x_{40}'), { y: 'center' }) });
      await wait('target formula', () => !!mount.querySelector(`[data-preview-from="${raw.indexOf('$$\n\\frac{x_{40}')}" ] .katex`));
      await frame(); await frame();
      const before = view.coordsAtPos(anchor)!.top, selection = view.state.selection;
      const layoutBefore = layout();
      await document.fonts.ready; await frame(); await frame();
      const after = view.coordsAtPos(anchor)!.top;
      scroll = { before, after, layoutBefore, layoutAfter: layout() };
      check('unvisited-formulas-enter-the-dom-with-rendered-content', inserted > 0 && placeholders === 0);
      check('upward-formula-scroll-has-no-second-layout-jump', Math.abs(after - before) <= 2);
      check('formula-layout-preserves-document-selection-and-history', editor.read() === raw && view.state.selection.eq(selection) && undoDepth(view.state) === 0);
    } finally { observer.disconnect(); }
  } finally { editor.destroy(); mount.remove(); }
  return { passed, failed, scroll };
}
