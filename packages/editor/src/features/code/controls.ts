import { LanguagePicker } from './language-picker.ts';
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
import { isPlainCode, codeLanguageForMarkdown } from './languages.ts';
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
      && view.dom.querySelector('input:focus, textarea:focus, select:focus, [data-code-language-input]:focus')) return false;
  try {
    if (command === 'code-language') {
      if (!block.fenced) throw new CodeError('indentedLanguage');
      view.dispatch({ effects: [focusContext.of('code'), showCodeControls.of(true)] });
      const doc = view.state.doc;
      queueMicrotask(() => {
        if (view.dom.isConnected && view.state.doc === doc) view.dom.querySelector<HTMLElement>('[data-code-language-input]')?.focus();
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
  private readonly picker: LanguagePicker;
  private readonly label = document.createElement('label');
  private readonly status = document.createElement('output');
  private readonly view: EditorView;
  private composing = false;
  constructor(view: EditorView) {
    this.view = view;
    this.dom.className = 'ot-code-tools'; this.dom.noValidate = true;
    this.dom.setAttribute('aria-label', tFor(view.state.facet(localeFacet), 'code.languageLabel'));
    const dismiss = () => {
      if (this.composing || view.composing || view.state.field(compositionState)) return;
      view.dispatch({ effects: [focusContext.of(null), showCodeControls.of(false)] }); view.focus();
    };
    this.picker = new LanguagePicker(view.state.field(codeControls).language,
      tFor(view.state.facet(localeFacet), 'code.languageLabel'), tFor(view.state.facet(localeFacet), 'code.plain'),
      value => view.dispatch({ effects: changeDraft.of(value) }), () => this.dom.requestSubmit(), dismiss,
      active => { this.composing = active; view.dispatch({ effects: changeComposition.of(active) }); });
    this.label.append(this.picker.dom);
    this.status.setAttribute('role', 'status'); this.dom.append(this.label);
    const close = document.createElement('button'); close.type = 'button'; close.name = 'code-close';
    close.textContent = tFor(view.state.facet(localeFacet), 'media.close'); close.addEventListener('click', dismiss);
    this.dom.append(close, this.status);
    this.dom.addEventListener('keydown', event => { if (event.key === 'Escape' && !event.isComposing) { event.preventDefault(); dismiss(); } });
    this.dom.addEventListener('submit', event => {
      event.preventDefault();
      if (this.composing || view.composing) return;
      try {
        const transaction = codeLanguageTransaction(view.state, view.state.field(codeControls).language);
        if (transaction) view.dispatch(transaction);
        dismiss();
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
    this.picker.setValue(draft.language);
    this.label.dataset.label = tFor(locale, 'code.languageLabel');
    this.picker.configure(tFor(locale, 'code.languageLabel'), tFor(locale, 'code.plain'), state.readOnly || !block?.fenced);
    this.status.textContent = draft.error ? codeErrorMessage(this.view, draft.error) : draft.copied ? tFor(locale, 'code.copied')
      : !isPlainCode(draft.original) && !codeLanguageForMarkdown(draft.original) ? tFor(locale, 'code.noHighlight', { language: draft.original }) : '';
    this.status.dataset.error = String(!!draft.error);
  }
  mount(): void { if (this.view.state.field(codeControls).force) this.picker.focus(); }
  destroy(): void { this.picker.destroy(); }
  update(_update: ViewUpdate): void { this.render(); }
}
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
  provide: field => contextualControls('code', field, (state, value) => value.visible ? codeBlockAt(state)?.bodyFrom ?? state.selection.main.head : null, createPanel),
});
