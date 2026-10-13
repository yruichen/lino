import { EditorView, ViewPlugin } from '@codemirror/view';
import { EditorState, StateEffect, StateField, type SelectionRange } from '@codemirror/state';

export const searchArrival = StateEffect.define<SelectionRange>();
const arrival = StateField.define<SelectionRange | null>({
  create: () => null,
  update(value, tr) {
    if (tr.docChanged || tr.selection) value = null;
    for (const effect of tr.effects) if (effect.is(searchArrival)) value = effect.value;
    return value;
  },
});

// Presentation follows an accepted search selection; it never changes text,
// matching, selection or undo. Geometry is read after CodeMirror lays out.
const arrivalFeedback = ViewPlugin.fromClass(class {
  private readonly view: EditorView;
  constructor(view: EditorView) { this.view = view; }
  update(update: import('@codemirror/view').ViewUpdate) {
    if (!update.transactions.some(tr => tr.isUserEvent('select.search')) || matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    const target = update.state.field(arrival);
    if (!target) return;
    if (target.eq(update.startState.selection.main)) return;
    this.view.requestMeasure({ read: view => {
      if (!view.state.selection.main.eq(target)) return null;
      return view.dom.querySelector('.cm-searchMatch-selected');
    }, write: node => { node?.animate?.([{ opacity: .4 }, { opacity: 1 }], { duration: 180 }); } });
  }
});
export const searchMotion = [arrival, arrivalFeedback,
  EditorState.transactionExtender.of(tr => {
    const effect = tr.effects.find(effect => effect.is(searchArrival));
    return effect ? { effects: EditorView.scrollIntoView(effect.value, { y: 'center' }) } : null;
  }),
  EditorView.scrollHandler.of((view, range) => {
    const target = view.state.field(arrival);
    if (!target?.eq(range) || matchMedia('(prefers-reduced-motion: reduce)').matches) return false;
    const rect = view.coordsAtPos(range.head), frame = view.scrollDOM.getBoundingClientRect();
    if (!rect || !frame.height) return false;
    view.scrollDOM.scrollTo({ top: Math.max(0, view.scrollDOM.scrollTop + rect.top - frame.top - frame.height / 2), behavior: 'smooth' });
    return true;
  }),
];
