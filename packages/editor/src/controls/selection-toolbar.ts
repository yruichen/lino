import { showTooltip, type EditorView, type TooltipView } from '@codemirror/view';
import { compositionState } from '../features/source-mode/state.ts';
import { applyFormat, type FormatCommand } from '../features/markdown/commands.ts';
import { localeFacet } from '../localization/editor.ts';
import { tFor, type Locale } from '../localization/index.ts';

type ToolbarLabel = 'format.bold' | 'format.italic' | 'format.strikethrough' | 'format.inlineCode' | 'format.highlight' | 'format.link' | 'format.clearInline';
type ToolbarAction = { command: FormatCommand; label: ToolbarLabel; symbol: string };
const actions: ToolbarAction[] = [
  { command: 'bold', label: 'format.bold', symbol: 'B' },
  { command: 'italic', label: 'format.italic', symbol: 'I' },
  { command: 'strikethrough', label: 'format.strikethrough', symbol: 'S' },
  { command: 'inline-code', label: 'format.inlineCode', symbol: '</>' },
  { command: 'highlight', label: 'format.highlight', symbol: 'H' },
  { command: 'link', label: 'format.link', symbol: '↗' },
  { command: 'clear-formatting', label: 'format.clearInline', symbol: '×' },
];

function createToolbar(view: EditorView, locale: Locale): TooltipView {
  const dom = document.createElement('div');
  const translateToolbar = (key: ToolbarLabel) => tFor(locale, key as 'format.bold');
  dom.className = 'ot-selection-toolbar';
  dom.setAttribute('role', 'toolbar');
  dom.setAttribute('aria-label', tFor(locale, 'format.selectionToolbar'));
  for (const action of actions) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = `ot-format-${action.command}`;
    button.textContent = action.symbol;
    button.title = translateToolbar(action.label);
    button.setAttribute('aria-label', translateToolbar(action.label));
    button.addEventListener('mousedown', event => event.preventDefault());
    button.addEventListener('click', () => { applyFormat(view, action.command); view.focus(); });
    dom.append(button);
  }
  return {
    dom,
    offset: { x: 0, y: 8 },
    getCoords: () => {
      const selection = view.state.selection.main;
      const start = view.coordsAtPos(selection.from);
      const end = view.coordsAtPos(selection.to);
      const fallback = view.scrollDOM.getBoundingClientRect();
      return {
        left: Math.min(start?.left ?? fallback.left, end?.left ?? fallback.left),
        right: Math.max(start?.right ?? fallback.right, end?.right ?? fallback.right),
        top: Math.min(start?.top ?? fallback.top, end?.top ?? fallback.top),
        bottom: Math.max(start?.bottom ?? fallback.bottom, end?.bottom ?? fallback.bottom),
      };
    },
  };
}

export const selectionToolbar = showTooltip.compute(['selection', localeFacet, compositionState], state => {
  const selection = state.selection.main;
  if (selection.empty || state.readOnly || state.field(compositionState)) return null;
  const locale = state.facet(localeFacet);
  return { pos: selection.from, above: true, create: view => createToolbar(view, locale) };
});
