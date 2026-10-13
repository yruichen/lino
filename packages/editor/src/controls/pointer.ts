import { StateEffect, StateField, type EditorSelection, type EditorState } from '@codemirror/state';
import { EditorView, ViewPlugin } from '@codemirror/view';
import { compositionState, modeState } from '../features/source-mode/state.ts';

const holdPresentation = StateEffect.define<boolean>();
const heldSelection = StateField.define<EditorSelection | null>({
  create: () => null,
  update(value, tr) {
    if (tr.docChanged || tr.state.field(compositionState) || tr.startState.field(modeState) !== tr.state.field(modeState)) return null;
    for (const effect of tr.effects) if (effect.is(holdPresentation)) value = effect.value ? tr.startState.selection : null;
    return value;
  },
});
/** A read-only display snapshot during a mouse gesture. Actual selection,
 * dragging, word/line selection and history continue to belong to CodeMirror.
 * Revealing markup mid-gesture can rewrap the clicked line, or collapse an old
 * media source above it, changing the coordinates under the same pointer. */
export function presentationSelection(state: EditorState): EditorSelection {
  return state.field(heldSelection, false) ?? state.selection;
}
export function presentationSelectionChanged(before: EditorState, after: EditorState): boolean {
  return !presentationSelection(before).eq(presentationSelection(after));
}
export const pointerPresentation = [heldSelection, ViewPlugin.fromClass(class {
  private disposed = false;
  private generation = 0;
  private readonly view: EditorView;
  private readonly release = () => {
    const expected = this.generation;
    // Native mouseup must finish resolving its selection against the old DOM
    // before selection-dependent Markdown is revealed.
    queueMicrotask(() => {
      if (!this.disposed && expected === this.generation && this.view.state.field(heldSelection))
        this.view.dispatch({ effects: [holdPresentation.of(false), this.view.scrollSnapshot()] });
    });
  };
  constructor(view: EditorView) {
    this.view = view; view.contentDOM.ownerDocument.addEventListener('mouseup', this.release);
    view.contentDOM.ownerDocument.defaultView?.addEventListener('blur', this.release);
  }
  start(event: MouseEvent): boolean {
    if (event.button !== 0 || this.view.composing || this.view.state.field(compositionState)
      || this.view.state.field(modeState) !== 'visual') return false;
    const target = event.target as Element;
    if (!this.view.contentDOM.contains(target) || target.closest('button, input, .ot-preview, .markdown-table')) return false;
    this.generation++; this.view.dispatch({ effects: holdPresentation.of(true) }); return false;
  }
  destroy() {
    this.disposed = true; this.view.contentDOM.ownerDocument.removeEventListener('mouseup', this.release);
    this.view.contentDOM.ownerDocument.defaultView?.removeEventListener('blur', this.release);
  }
}, { eventHandlers: { mousedown(event) { return this.start(event); } } })];
