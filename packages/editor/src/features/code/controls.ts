import { StateEffect, StateField, Transaction } from '@codemirror/state';
import { type EditorView, type Panel, type ViewUpdate } from '@codemirror/view';
import { contextualControls, focusContext } from '../../controls/contextual.ts';
import { searchPanelOpen } from '@codemirror/search';
import { type CodeCommand } from '@lino/protocol/editor-host';
import { localeFacet } from '../../localization/editor.ts';
import { tFor } from '../../localization/index.ts';
import { formatError } from '../../localization/errors.ts';
import { changeComposition, compositionState, modeState } from '../source-mode/state.ts';
import { codeIndentTransaction, codeLanguageTransaction } from './commands.ts';
import { codeBlockAt, codeContents, selectedCodeLines, CodeError } from './model.ts';
import { codeLanguages, isPlainCode, languageForCode } from './languages.ts';
import { codeOptions, codeViewTransaction } from './state.ts';

const showCodeControls = StateEffect.define<boolean>();
const changeDraft = StateEffect.define<string>();
const feedback = StateEffect.define<{ error?: unknown; copied?: boolean }>();
interface CodeDraft { from?: number; original: string; language: string; force: boolean; visible: boolean; error?: unknown; copied?: boolean }
export type WriteClipboard = (text: string) => Promise<void>;
const writers = new WeakMap<EditorView, WriteClipboard>();
export function setCodeClipboard(view: EditorView, write: WriteClipboard): void { writers.set(view, write); }
export function codeErrorMessage(view: EditorView, error: unknown): string {
  return error instanceof CodeError ? tFor(view.state.facet(localeFacet), `code.${error.code}`) : formatError(error);
}
function report(view: EditorView, error: unknown): void { view.dispatch({ effects: [focusContext.of('code'), feedback.of({ error })] }); }
export function runCodeCommand(view: EditorView, command: CodeCommand): boolean {
  const block = codeBlockAt(view.state);
  if (!block) { report(view, new CodeError('selectBlock')); return false; }
  if (view.composing || view.state.field(compositionState, false)) return false;
  // Native document commands cannot indent the document behind a language input.
  if (command !== 'code-language' && command !== 'code-copy'
      && view.dom.querySelector('input:focus, textarea:focus, select:focus')) return false;
  try {
    if (command === 'code-language') {
      if (!block.fenced) throw new CodeError('indentedLanguage');
      view.dispatch({ effects: [focusContext.of('code'), showCodeControls.of(true)] });
      const doc = view.state.doc;
      queueMicrotask(() => {
        if (view.dom.isConnected && view.state.doc === doc) view.dom.querySelector<HTMLInputElement>('.ot-code-tools input[name=code-language]')?.focus();
      });
    } else if (command === 'code-line-numbers' || command === 'code-wrap') {
      const options = view.state.field(codeOptions);
      view.dispatch(codeViewTransaction(command === 'code-wrap' ? { wrap: !options.wrap } : { numbers: !options.numbers }));
    } else if (command === 'code-copy') {
      const write = writers.get(view);
      if (!write) throw new CodeError('clipboard');
      const doc = view.state.doc;
      const finish = (value: { copied?: boolean; error?: unknown }) => {
        if (view.dom.isConnected && view.state.doc === doc && codeBlockAt(view.state)?.from === block.from) view.dispatch({ effects: [focusContext.of('code'), feedback.of(value)] });
      };
      void write(codeContents(view.state, block)).then(() => finish({ copied: true }), error => finish({ error }));
    } else {
      const transaction = codeIndentTransaction(view.state, command === 'code-indent' ? 1 : -1);
      if (!transaction) return false;
      view.dispatch(transaction); view.focus();
    }
    return true;
  } catch (error) { report(view, error); return false; }
}
class CodePanel implements Panel {
  readonly dom = document.createElement('form');
  private readonly input = document.createElement('input');
  private readonly label = document.createElement('label');
  private readonly status = document.createElement('output');
  private readonly view: EditorView;
  private composing = false;
  constructor(view: EditorView) {
    this.view = view;
    this.dom.className = 'ot-code-tools'; this.dom.noValidate = true;
    this.dom.setAttribute('aria-label', tFor(view.state.facet(localeFacet), 'code.languageLabel'));
    this.input.name = 'code-language'; this.input.maxLength = 80; this.input.autocomplete = 'off';
    const list = document.createElement('datalist');
    list.id = `ot-code-languages-${++panelSequence}`; this.input.setAttribute('list', list.id);
    const plain = list.appendChild(document.createElement('option')); plain.value = 'text'; plain.label = tFor(view.state.facet(localeFacet), 'code.plain');
    for (const language of codeLanguages) {
      const option = list.appendChild(document.createElement('option')); option.value = language.id; option.label = language.name;
    }
    this.label.append(this.input);
    this.status.setAttribute('role', 'status');
    this.dom.append(this.label, list);
    const close = document.createElement('button'); close.type = 'button'; close.name = 'code-close';
    const dismiss = () => {
      if (this.composing || view.composing || view.state.field(compositionState)) return;
      view.dispatch({ effects: [focusContext.of(null), showCodeControls.of(false)] }); view.focus();
    };
    close.textContent = tFor(view.state.facet(localeFacet), 'media.close'); close.addEventListener('click', dismiss);
    this.dom.append(close, this.status);
    this.dom.addEventListener('keydown', event => { if (event.key === 'Escape' && !event.isComposing) { event.preventDefault(); dismiss(); } });
    this.input.addEventListener('input', () => view.dispatch({ effects: changeDraft.of(this.input.value) }));
    this.input.addEventListener('compositionstart', () => { this.composing = true; view.dispatch({ effects: changeComposition.of(true) }); });
    this.input.addEventListener('compositionend', () => { this.composing = false; view.dispatch({ effects: [changeDraft.of(this.input.value), changeComposition.of(false)] }); });
    this.input.addEventListener('keydown', event => {
      if (event.key === 'Enter' && !event.isComposing && !this.composing) {
        event.preventDefault(); event.stopPropagation(); this.dom.requestSubmit();
      }
    });
    this.dom.addEventListener('submit', event => {
      event.preventDefault();
      if (this.composing || view.composing) return;
      try {
        const transaction = codeLanguageTransaction(view.state, view.state.field(codeControls).language);
        if (transaction) view.dispatch(transaction);
        view.focus();
      } catch (error) { report(view, error); }
    });
    this.render();
  }
  private render(): void {
    const state = this.view.state, draft = state.field(codeControls), block = codeBlockAt(state);
    const locale = state.facet(localeFacet);
    this.label.hidden = !draft.force;
    this.dom.querySelector<HTMLButtonElement>('button[name=code-close]')!.textContent = tFor(locale, 'media.close');
    this.dom.setAttribute('aria-label', tFor(locale, 'code.languageLabel'));
    if (this.input.value !== draft.language) this.input.value = draft.language;
    this.input.setAttribute('aria-label', tFor(locale, 'code.languageLabel'));
    this.label.dataset.label = tFor(locale, 'code.languageLabel');
    this.input.placeholder = tFor(locale, 'code.plain');
    this.input.disabled = state.readOnly || !block?.fenced;
    this.status.textContent = draft.error ? codeErrorMessage(this.view, draft.error) : draft.copied ? tFor(locale, 'code.copied')
      : !isPlainCode(draft.original) && !languageForCode(draft.original) ? tFor(locale, 'code.noHighlight', { language: draft.original }) : '';
    this.status.dataset.error = String(!!draft.error);
  }
  update(_update: ViewUpdate): void { this.render(); }
}
let panelSequence = 0;
const createPanel = (view: EditorView): Panel => new CodePanel(view);
export const codeControls = StateField.define<CodeDraft>({
  create(state) {
    const block = codeBlockAt(state);
    return { from: block?.from, original: block?.language ?? '', language: block?.language ?? '', force: false,
      visible: false };
  },
  update(value, transaction) {
    const block = codeBlockAt(transaction.state);
    const previousFrom = value.from === undefined ? undefined : transaction.changes.mapPos(value.from, 1);
    if (block?.from !== previousFrom || (block?.language ?? '') !== value.original) value = {
      from: block?.from, original: block?.language ?? '', language: block?.language ?? '', force: false, visible: false,
    };
    else if (transaction.docChanged) value = { ...value, from: block?.from, copied: false };
    if (transaction.startState.field(modeState) !== transaction.state.field(modeState)) value = { ...value, force: false };
    for (const effect of transaction.effects) {
      if (effect.is(changeDraft)) value = { ...value, language: effect.value, error: undefined, copied: false };
      if (effect.is(showCodeControls)) value = { ...value, force: effect.value, error: undefined, copied: false };
      if (effect.is(feedback)) value = { ...value, error: effect.value.error, copied: effect.value.copied };
    }
    const visible = !searchPanelOpen(transaction.state) && (!!block && value.force || !!value.error || !!value.copied);
    return { ...value, visible };
  },
  provide: field => contextualControls('code', field, (state, value) => value.visible ? state.selection.main.head : null, createPanel),
});
