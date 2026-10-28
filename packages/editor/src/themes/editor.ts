import { Compartment, Facet, type Extension } from '@codemirror/state';
import { HighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { EditorView, ViewPlugin } from '@codemirror/view';
import { tags } from '@lezer/highlight';
import type { EditorPreferences } from '../../../protocol/src/generated/EditorPreferences.ts';
import { applyThemeTokens, selectedTheme } from './catalog.ts';

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
      // Layout belongs to the editor theme, which has precedence over CM's
      // base theme. A bare .cm-content stylesheet rule loses to .ͼ1 .cm-content.
      '& > .cm-scroller': { fontFamily: 'inherit', lineHeight: 'inherit', justifyContent: 'center' },
      '& > .cm-scroller > .cm-content': {
        caretColor: 'var(--ot-caret)', width: '100%', maxWidth: 'var(--ot-reading-width)',
        minWidth: '0', flexGrow: '0', flexShrink: '1', margin: '0 auto',
        padding: '32px clamp(24px, 4vw, 56px) 120px', boxSizing: 'border-box',
      },
      '.cm-line': { padding: '0' },
      '.cm-activeLine': { backgroundColor: 'var(--ot-active-line)' },
      '.cm-activeLineGutter': { backgroundColor: 'transparent' },
      '.cm-cursor, .cm-dropCursor': { borderLeftColor: 'var(--ot-caret)' },
      '&.cm-focused .cm-selectionBackground, .cm-selectionBackground, ::selection': { backgroundColor: 'var(--ot-selection)' },
      '.cm-panels': { color: 'var(--ot-text)', backgroundColor: 'var(--ot-panel)' },
    }, { dark }),
    highlighting,
  ];
}
export const preferredAppearance = Facet.define<string, string>({ combine: values => values[0] ?? 'system' });
export const themePreferences = Facet.define<EditorPreferences, EditorPreferences | undefined>({ combine: values => values[0] });

export function editorTheme(): Extension {
  const appearance = new Compartment();
  const system = matchMedia('(prefers-color-scheme: dark)');
  const dark = (view: EditorView) => view.state.facet(preferredAppearance) === 'dark' || (view.state.facet(preferredAppearance) === 'system' && system.matches);
  return [appearance.of(themeConfiguration(system.matches)), ViewPlugin.fromClass(class {
    private disposed = false;
    private queued = false;
    private applied?: EditorPreferences;
    private appliedDark?: boolean;
    private readonly changed = () => this.schedule();
    private readonly view: EditorView;
    constructor(view: EditorView) { this.view = view; system.addEventListener('change', this.changed); this.schedule(); }
    update() { this.schedule(); }
    private schedule() {
      if (this.queued || this.disposed) return;
      this.queued = true;
      queueMicrotask(() => {
        this.queued = false;
        if (this.disposed) return;
        const preferences = this.view.state.facet(themePreferences), isDark = dark(this.view);
        if (this.applied !== preferences || this.appliedDark !== isDark) {
          applyThemeTokens(this.view.dom, selectedTheme(preferences), isDark);
          if (this.view.dom.closest('#editor')) {
            const page = this.view.dom.ownerDocument.documentElement;
            applyThemeTokens(page, selectedTheme(preferences), isDark);
            page.style.colorScheme = isDark ? 'dark' : 'light';
          }
          this.applied = preferences; this.appliedDark = isDark;
        }
        if (this.view.state.facet(EditorView.darkTheme) !== isDark)
          this.view.dispatch({ effects: appearance.reconfigure(themeConfiguration(isDark)) });
      });
    }
    destroy() { this.disposed = true; system.removeEventListener('change', this.changed); }
  })];
}
