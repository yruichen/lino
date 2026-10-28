import { Compartment, EditorSelection, EditorState } from '@codemirror/state';
import { defaultKeymap, history, historyKeymap, indentLess, indentMore, redo, redoDepth, undo, undoDepth } from '@codemirror/commands';
import { StreamLanguage } from '@codemirror/language';
import { stex } from '@codemirror/legacy-modes/mode/stex';
import { SearchQuery, getSearchQuery, setSearchQuery } from '@codemirror/search';
import { EditorView, keymap } from '@codemirror/view';
import type { EditorPreferences } from '@lino/protocol/generated/EditorPreferences';
import type { EditorCommand, EditorHostEvent, EditorStatus } from '@lino/protocol/editor-host';
import type { SaveTarget } from '@lino/protocol/generated/SaveTarget';
import type { SaveTicket } from '@lino/protocol/generated/SaveTicket';
import { sourceDocument } from '../transactions/line-endings.ts';
import { documentSearch } from '../features/search/panel.ts';
import { replacementVisible, runSearchCommand } from '../features/search/commands.ts';
import { nativeSearchUI, searchProjection } from '../features/search/state.ts';
import { goToLine, lineNavigation } from '../features/navigation/line.ts';
import { editorLocalization } from '../localization/editor.ts';
import { editorTheme, preferredAppearance, themePreferences } from '../themes/editor.ts';
import { bodyFont, selectedTheme } from '../themes/catalog.ts';
import { t } from '../localization/index.ts';

/**
 * LaTeX deliberately uses a source-only profile. It shares the document
 * transport and CodeMirror input model with Markdown, but does not run the
 * Markdown presentation or mutation extensions over TeX source.
 */
export class LatexEditor {
  readonly view: EditorView;
  private readonly source;
  private readonly emit: (event: EditorHostEvent) => void;
  private readonly onChange: (docChanged: boolean) => void;
  private readonly writable = new Compartment();
  private readonly preferences = new Compartment();
  private frozen = false;
  private documentReadOnly = false;
  private disposed = false;
  private exportCapture = false;
  private querySequence = 0n;
  private zoom = 1;

  constructor(parent: HTMLElement, raw: string, emit: (event: EditorHostEvent) => void,
    onChange: (docChanged: boolean) => void = () => {}) {
    this.emit = emit;
    this.onChange = onChange;
    this.source = sourceDocument(raw);
    this.view = new EditorView({ parent, state: EditorState.create({
      doc: this.source.doc,
      extensions: [
        this.writable.of(EditorState.readOnly.of(false)),
        this.source.extension,
        history(),
        keymap.of([...historyKeymap, ...defaultKeymap]),
        editorTheme(),
        editorLocalization(),
        StreamLanguage.define(stex),
        documentSearch,
        nativeSearchUI.of(true),
        lineNavigation,
        EditorView.lineWrapping,
        EditorView.contentAttributes.of({ spellcheck: 'false' }),
        EditorView.updateListener.of(update => {
          this.publish();
          this.onChange(update.docChanged);
        }),
      ],
    }) });
    this.emit({ kind: 'outline', token: 'latex', entries: [], current: null, complete: true, truncated: false, exhausted: true });
    this.emit({ kind: 'statistics', counts: { words: 0, characters: 0, nonWhitespace: 0, lines: 0 }, selection: false, visible: false });
    this.publish();
  }

  read(): string { return this.source.read(this.view.state); }
  composing(): boolean { return this.view.composing; }
  async settleResources(): Promise<void> {}
  async settleComposition(): Promise<void> {
    const started = Date.now();
    while (this.composing()) {
      if (Date.now() - started > 10000) throw new Error(t('editor.finishComposition'));
      await new Promise(resolve => setTimeout(resolve, 20));
    }
  }
  async captureExport(): Promise<void> {
    if (this.disposed || this.exportCapture) throw new Error(t('document.saving'));
    this.exportCapture = true;
  }
  endExportCapture(): void { this.exportCapture = false; }
  async applyPreferences(values: EditorPreferences): Promise<void> {
    if (this.disposed) return;
    const theme = selectedTheme(values);
    const size = values.use_theme_font_size ? theme.font_size : values.font_size;
    const height = values.use_theme_line_height ? theme.line_height : values.line_height;
    this.view.dispatch({ effects: this.preferences.reconfigure([
      preferredAppearance.of(values.theme),
      themePreferences.of(values),
      EditorView.contentAttributes.of({ spellcheck: String(values.spell_check) }),
      EditorView.theme({
        '& > .cm-scroller > .cm-content': {
          fontFamily: bodyFont(values),
          fontSize: `calc(${size}px * var(--ot-editor-scale, 1))`,
          lineHeight: String(height / 100),
          maxWidth: values.content_width === 'fixed' ? `${values.page_width}px` : 'var(--ot-reading-width)',
        },
      }),
    ]) });
  }
  setReadOnly(value: boolean): void { this.frozen = value; this.updateReadOnly(); }
  setDocumentReadOnly(value: boolean): void { this.documentReadOnly = value; this.updateReadOnly(); }
  private updateReadOnly(): void {
    this.view.dispatch({ effects: this.writable.reconfigure(EditorState.readOnly.of(this.frozen || this.documentReadOnly)) });
  }
  setViewportWidth(width: number): void {
    if (!Number.isFinite(width) || width <= 0) return;
    this.view.dom.style.width = `${width}px`;
    this.view.dom.style.marginInline = 'auto';
    this.view.requestMeasure();
  }
  canReplaceEmpty(): boolean {
    return this.view.state.doc.length === 0 && undoDepth(this.view.state) === 0 && redoDepth(this.view.state) === 0;
  }
  appearance(): 'light' | 'dark' { return this.view.state.facet(EditorView.darkTheme) ? 'dark' : 'light'; }
  setOutlineVisible(_visible: boolean, _sequence: string): void {}
  continueOutline(): void {}
  acceptsHeading(_from: number, _token: string): boolean { return false; }
  prepareImageDrop(_x: number, _y: number): boolean { return false; }
  cancelImageDrop(): void {}
  async commitImageDrop(_paths: string[]): Promise<void> { throw new Error(t('media.importCancelled')); }
  refreshResources(): void {}
  setLocale(_value: unknown): void {}

  search(text: string, sequence?: string): void {
    if (sequence !== undefined) {
      if (!/^\d+$/.test(sequence)) throw new Error(t('editor.unknownCommand'));
      const next = BigInt(sequence);
      if (next <= this.querySequence) return;
      this.querySequence = next;
    }
    const previous = getSearchQuery(this.view.state);
    this.view.dispatch({ effects: setSearchQuery.of(new SearchQuery({ ...previous, search: text })) });
  }
  command(command: EditorCommand): boolean {
    if (command === 'toggle-source' || command === 'source' || command === 'visual') return true;
    if (command === 'find' || command === 'replace' || command === 'find-next' || command === 'find-previous' || command === 'toggle-find' || command === 'close-find') {
      return runSearchCommand(this.view, command);
    }
    if (command === 'goto-line') return goToLine(this.view);
    if (command === 'undo' || command === 'redo') {
      if (this.view.state.readOnly) return false;
      return (command === 'undo' ? undo : redo)(this.view);
    }
    if (command === 'indent' || command === 'outdent') {
      if (this.view.state.readOnly) return false;
      return (command === 'indent' ? indentMore : indentLess)(this.view);
    }
    if (command === 'zoom-in' || command === 'zoom-out' || command === 'zoom-reset') {
      this.zoom = command === 'zoom-reset' ? 1 : Math.max(.5, Math.min(3, this.zoom + (command === 'zoom-in' ? .1 : -.1)));
      this.view.dom.style.setProperty('--ot-editor-scale', String(this.zoom));
      this.publish();
      return true;
    }
    return ['toggle-outline', 'toggle-statistics', 'focus-mode', 'typewriter-mode'].includes(command);
  }
  snapshot() { return { text: this.read(), selection: this.view.state.selection.toJSON(), ...this.status() }; }
  status(): EditorStatus {
    const selection = this.view.state.selection.main;
    const line = this.view.state.doc.lineAt(selection.head);
    return {
      mode: 'source', composing: this.composing(), pendingMode: false,
      canUndo: !this.view.state.readOnly && undoDepth(this.view.state) > 0,
      canRedo: !this.view.state.readOnly && redoDepth(this.view.state) > 0,
      changedFromInitial: !this.view.state.doc.eq(this.source.doc), codeBlock: false, codeFenced: false, codeCanIndent: false,
      codeWrap: false, codeNumbers: false, outline: false, statistics: false,
      focus: false, typewriter: false, zoom: this.zoom,
      cursorLine: line.number, cursorColumn: selection.head - line.from + 1, selectionLength: selection.to - selection.from,
      search: searchProjection(this.view.state, this.view.state.field(replacementVisible), String(this.querySequence)),
    };
  }
  private publish(): void { if (!this.disposed) this.emit({ kind: 'status', status: this.status() }); }
  destroy(): void { this.disposed = true; this.view.destroy(); }
}