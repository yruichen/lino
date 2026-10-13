import { EditorSelection, StateEffect, StateField, type EditorState } from '@codemirror/state';
import { syntaxTree } from '@codemirror/language';
import { EditorView, getPanel, keymap, showPanel, type Panel } from '@codemirror/view';
import { localeFacet } from '../../localization/editor.ts';
import { tFor } from '../../localization/index.ts';
import { changeMode, compositionState } from '../source-mode/state.ts';

interface LineDraft { value: string; attempted: boolean }
const setLineDraft = StateEffect.define<LineDraft | null>();
// Language changes can rebuild CodeMirror panels. Keep the unsubmitted draft
// in this editor's state, outside text changes and document undo history.
const lineDraft = StateField.define<LineDraft | null>({
  create: () => null,
  update: (draft, transaction) => transaction.effects.reduce((value, effect) => effect.is(setLineDraft) ? effect.value : value, draft),
  provide: field => showPanel.from(field, draft => draft ? createLinePanel : null),
});

// Line numbers refer to the current normalized editing document. Choosing the
// start of a line avoids treating UTF-16 offsets as user-facing columns.
export function linePosition(state: EditorState, value: string): number | null {
  if (!/^[1-9]\d*$/.test(value.trim())) return null;
  const number = Number(value.trim());
  return Number.isSafeInteger(number) && number <= state.doc.lines ? state.doc.line(number).from : null;
}

function composing(view: EditorView): boolean {
  return view.composing || view.state.field(compositionState, false) === true;
}

function createLinePanel(view: EditorView): Panel {
  const dom = document.createElement('form');
  dom.className = 'ot-goto-line';
  const label = dom.appendChild(document.createElement('label'));
  const title = label.appendChild(document.createElement('span'));
  const input = label.appendChild(document.createElement('input'));
  input.name = 'line'; input.inputMode = 'numeric'; input.autocomplete = 'off';
  input.className = 'cm-textfield';
  const go = dom.appendChild(document.createElement('button'));
  go.type = 'submit'; go.className = 'cm-button';
  const close = dom.appendChild(document.createElement('button'));
  close.type = 'button'; close.className = 'cm-button';
  const error = dom.appendChild(document.createElement('output'));
  error.setAttribute('aria-live', 'polite');
  let inputComposing = false;
  const update = () => {
    const draft = view.state.field(lineDraft);
    if (!draft) return;
    if (!inputComposing && input.value !== draft.value) input.value = draft.value;
    const locale = view.state.facet(localeFacet);
    title.textContent = tFor(locale, 'navigation.label');
    input.setAttribute('aria-label', title.textContent);
    go.textContent = tFor(locale, 'navigation.go');
    close.textContent = tFor(locale, 'navigation.close');
    const invalid = draft.attempted && linePosition(view.state, input.value) === null;
    input.setAttribute('aria-invalid', String(invalid));
    error.textContent = invalid ? tFor(locale, 'navigation.invalid', { max: view.state.doc.lines }) : '';
    go.disabled = composing(view) || inputComposing;
  };
  const dismiss = () => {
    if (composing(view) || inputComposing) return;
    view.dispatch({ effects: setLineDraft.of(null) }); view.focus();
  };
  close.addEventListener('click', dismiss);
  const commitInput = () => view.dispatch({ effects: setLineDraft.of({ value: input.value, attempted: false }) });
  input.addEventListener('input', () => { if (!inputComposing) commitInput(); });
  input.addEventListener('compositionstart', () => { inputComposing = true; update(); });
  input.addEventListener('compositionend', () => { inputComposing = false; commitInput(); });
  dom.addEventListener('keydown', event => {
    if (event.isComposing || composing(view) || inputComposing) return;
    if (event.key === 'Escape') { event.preventDefault(); dismiss(); }
  });
  dom.addEventListener('submit', event => {
    event.preventDefault();
    if (composing(view) || inputComposing) return;
    const position = linePosition(view.state, input.value);
    if (position === null) {
      view.dispatch({ effects: setLineDraft.of({ value: input.value, attempted: true }) });
      input.focus(); return;
    }
    // A replaced table has no caret for its hidden source rows. Reveal source
    // only when the requested line is inside that block, preserving all text.
    let inTable = false;
    syntaxTree(view.state).iterate({ from: position, to: position, enter(node) {
      if (node.name === 'Table') { inTable = true; return false; }
    } });
    view.dispatch({ selection: EditorSelection.cursor(position), effects: [
      setLineDraft.of(null), ...(inTable ? [changeMode.of('source')] : []),
      EditorView.scrollIntoView(position, { y: 'center' }),
    ] });
    view.focus();
  });
  update();
  return { dom, top: true, mount: () => { input.focus(); input.select(); }, update };
}

export function goToLine(view: EditorView): boolean {
  if (composing(view)) return false;
  if (!view.state.field(lineDraft)) view.dispatch({ effects: setLineDraft.of({
    value: String(view.state.doc.lineAt(view.state.selection.main.head).number), attempted: false,
  }) });
  const input = getPanel(view, createLinePanel)?.dom.querySelector('input');
  input?.focus(); input?.select();
  return true;
}

export const lineNavigation = [lineDraft, keymap.of([{ key: 'Mod-Alt-g', run: goToLine }])];
