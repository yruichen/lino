import { Compartment, EditorState } from '@codemirror/state';
import { EditorView, keymap, placeholder } from '@codemirror/view';
import { autocompletion, acceptCompletion, closeCompletion, completionKeymap } from '@codemirror/autocomplete';
import { codeLanguageChoices } from './languages.ts';

/** CodeMirror's official completion UI owns suggestion filtering, keyboard,
 * ARIA and IME. This small editor contains only a language draft, never Markdown. */
export class LanguagePicker {
  readonly dom = document.createElement('div');
  readonly editor: EditorView;
  private readonly writable = new Compartment();
  private readonly labels = new Compartment();
  private syncing = false;
  constructor(value: string, label: string, plain: string, changed: (value: string) => void,
    submit: () => void, dismiss: () => void, composition: (active: boolean) => void) {
    this.dom.className = 'ot-code-input';
    this.editor = new EditorView({ parent: this.dom, state: EditorState.create({ doc: value, extensions: [
      this.writable.of(EditorState.readOnly.of(false)),
      this.labels.of([placeholder(plain), EditorView.contentAttributes.of({ 'aria-label': label, 'data-code-language-input': 'true' })]),
      EditorState.transactionFilter.of(tr => tr.newDoc.length <= 80 && tr.newDoc.lines === 1 ? tr : []),
      EditorView.updateListener.of(update => { if (update.docChanged && !this.syncing) changed(update.state.doc.toString()); }),
      autocompletion({ defaultKeymap: false, selectOnOpen: false, maxRenderedOptions: 6, override: [context => context.state.doc.length || context.explicit ? ({ from: 0, to: context.state.doc.length,
        validFor: /^[\w.+#-]*$/, options: codeLanguageChoices.map(language => ({ label: language.id, displayLabel: language.name,
          detail: language.id, boost: value.toLowerCase() === language.id ? 1 : 0,
          apply: (view, _completion, from, to) => {
            view.dispatch({ changes: { from, to, insert: language.id }, selection: { anchor: from + language.id.length } });
            queueMicrotask(submit);
          },
        })),
      }) : null] }),
      keymap.of([
        { key: 'Enter', run: view => { if (!acceptCompletion(view)) submit(); return true; } },
        { key: 'Escape', run: view => { closeCompletion(view); dismiss(); return true; } },
        ...completionKeymap.filter(binding => binding.key !== 'Enter' && binding.key !== 'Escape'),
      ]),
      EditorView.domEventHandlers({
        compositionstart: () => { composition(true); return false; },
        compositionend: () => { composition(false); return false; },
      }),
      EditorView.theme({ '&': { height: 'auto', fontSize: '13px', lineHeight: '1.5', background: 'transparent' },
        '.cm-content': { padding: '5px 8px', minHeight: '0' }, '.cm-line': { padding: '0' },
        '.cm-scroller': { overflow: 'visible', fontFamily: 'inherit' },
        '.cm-tooltip-autocomplete': { background: 'var(--ot-panel)', color: 'var(--ot-text)', border: '1px solid var(--ot-border)', borderRadius: '8px' },
        '.cm-tooltip-autocomplete ul': { maxHeight: '144px', fontFamily: 'inherit' },
        '.cm-tooltip-autocomplete ul li[aria-selected]': { background: 'var(--ot-active)', color: 'var(--ot-text)' },
      }),
    ] }) });
  }
  setValue(value: string): void {
    if (this.editor.state.doc.toString() === value) return;
    this.syncing = true;
    try { this.editor.dispatch({ changes: { from: 0, to: this.editor.state.doc.length, insert: value } }); }
    finally { this.syncing = false; }
  }
  configure(label: string, plain: string, readOnly: boolean): void {
    this.editor.dispatch({ effects: [this.writable.reconfigure(EditorState.readOnly.of(readOnly)),
      this.labels.reconfigure([placeholder(plain), EditorView.contentAttributes.of({ 'aria-label': label, 'data-code-language-input': 'true' })])] });
  }
  focus(): void { this.editor.focus(); this.editor.dispatch({ selection: { anchor: 0, head: this.editor.state.doc.length } }); }
  destroy(): void { this.editor.destroy(); }
}
