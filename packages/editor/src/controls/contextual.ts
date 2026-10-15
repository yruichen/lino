import { StateEffect, StateField, type EditorState } from '@codemirror/state';
import { EditorView, showTooltip, tooltips, type Panel, type TooltipView } from '@codemirror/view';
import { localeFacet } from '../localization/editor.ts';
import { compositionState } from '../features/source-mode/state.ts';

type Context = 'code' | 'media' | 'table' | 'reference';
export const focusContext = StateEffect.define<Context | null>();
// Only presentation focus is shared. Drafts, anchors and mutations stay in
// their features. An explicit form takes precedence over automatic code tools.
const contextOwner = StateField.define<Context | null>({
  create: () => null,
  update(value, tr) {
    if (tr.selection && !tr.startState.selection.eq(tr.state.selection)) value = null;
    for (const effect of tr.effects) if (effect.is(focusContext)) value = effect.value;
    return value;
  },
});

/** Reuse feature-owned forms/drafts, anchored to their mapped document range.
 * CodeMirror owns viewport clipping, scrolling and destruction; no second
 * selection, document state or positioning timers live in this layer. */
export function contextualControls<Value>(context: Context, field: StateField<Value>, anchor: (state: EditorState, value: Value) => number | null,
  form: (view: EditorView) => Panel) {
  const create = (view: EditorView): TooltipView => {
    const panel = form(view);
    panel.dom.classList.add('ot-contextual-controls');
    panel.dom.setAttribute('role', 'dialog');
    return { dom: panel.dom, offset: { x: 0, y: context === 'code' ? 4 : 10 },
      ...(context === 'code' ? { getCoords: (pos: number) => {
        const badge = [...view.dom.querySelectorAll<HTMLElement>('.ot-code-language-anchor')].find(node => Number(node.dataset.codeBodyFrom) === pos);
        const rect = badge?.querySelector('button')?.getBoundingClientRect() ?? view.coordsAtPos(pos) ?? view.scrollDOM.getBoundingClientRect();
        return { left: rect.right - 220, right: rect.right, top: rect.top, bottom: rect.bottom };
      } } : {}),
      mount: () => panel.mount?.(), update: update => panel.update?.(update), destroy: () => panel.destroy?.() };
  };
  return [contextOwner, showTooltip.compute([field, contextOwner, 'selection', localeFacet], state => {
    const owner = state.field(contextOwner);
    if (owner !== context) return null;
    const pos = anchor(state, state.field(field));
    return pos === null ? null : { pos: Math.max(0, Math.min(state.doc.length, pos)), above: false, create };
  })];
}

export const contextualViewport = [contextOwner, EditorView.domEventHandlers({ mousedown: (event, view) => {
  if (view.contentDOM.contains(event.target as Node) && view.state.field(contextOwner) && !view.composing && !view.state.field(compositionState))
    view.dispatch({ effects: focusContext.of(null) });
  return false;
} }), tooltips({ tooltipSpace: view => {
  const rect = view.scrollDOM.getBoundingClientRect();
  return { left: rect.left + 12, right: rect.right - 12, top: rect.top + 8, bottom: rect.bottom - 8 };
} })];
