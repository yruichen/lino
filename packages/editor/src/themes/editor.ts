import { Compartment, type Extension } from '@codemirror/state';
import { HighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { EditorView, ViewPlugin } from '@codemirror/view';
import { tags } from '@lezer/highlight';

const highlighting = syntaxHighlighting(HighlightStyle.define([
  { tag: tags.heading, color: 'var(--ot-heading)', fontWeight: '600' },
  { tag: tags.strong, fontWeight: '700' },
  { tag: tags.emphasis, fontStyle: 'italic' },
  { tag: tags.strikethrough, textDecoration: 'line-through' },
  { tag: [tags.link, tags.url], color: 'var(--ot-link)' },
  { tag: [tags.keyword, tags.atom, tags.bool], color: 'var(--ot-keyword)' },
  { tag: [tags.string, tags.inserted], color: 'var(--ot-string)' },
  { tag: [tags.number, tags.literal], color: 'var(--ot-number)' },
  { tag: [tags.comment, tags.meta, tags.processingInstruction], color: 'var(--ot-muted)' },
  { tag: tags.invalid, color: 'var(--ot-error)' },
]));

/** One appearance value configures both CodeMirror and the CSS color scheme. */
export function themeConfiguration(dark: boolean): Extension {
  return [
    EditorView.editorAttributes.of({ 'data-appearance': dark ? 'dark' : 'light' }),
    EditorView.theme({
      '&': { color: 'var(--ot-text)', backgroundColor: 'var(--ot-background)' },
      '.cm-content': { caretColor: 'var(--ot-caret)' },
      '.cm-cursor, .cm-dropCursor': { borderLeftColor: 'var(--ot-caret)' },
      '&.cm-focused .cm-selectionBackground, .cm-selectionBackground, ::selection': { backgroundColor: 'var(--ot-selection)' },
      '.cm-panels': { color: 'var(--ot-text)', backgroundColor: 'var(--ot-panel)' },
    }, { dark }),
    highlighting,
  ];
}

export function editorTheme(): Extension {
  const appearance = new Compartment();
  const system = matchMedia('(prefers-color-scheme: dark)');
  return [appearance.of(themeConfiguration(system.matches)), ViewPlugin.fromClass(class {
    private readonly changed = (event: MediaQueryListEvent) => {
      this.view.dispatch({ effects: appearance.reconfigure(themeConfiguration(event.matches)) });
    };
    constructor(private readonly view: EditorView) { system.addEventListener('change', this.changed); }
    destroy() { system.removeEventListener('change', this.changed); }
  })];
}
