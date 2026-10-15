import { Compartment, EditorSelection, EditorState, Prec } from '@codemirror/state';
import { defaultKeymap, history, historyKeymap, redo, redoDepth, undo, undoDepth, indentMore, indentLess } from '@codemirror/commands';
import { markdown, markdownLanguage, markdownKeymap } from '@codemirror/lang-markdown';
import { EditorView, keymap } from '@codemirror/view';
import { codeCommands, mediaCommands, referenceCommands, type ReferenceCommand, type MediaCommand, type CodeCommand, type EditorCommand, type EditorHostEvent, type EditorStatus } from '@lino/protocol/editor-host';
import type { AssetPort } from '@lino/protocol/assets';
import type { EditorPreferences } from '@lino/protocol/generated/EditorPreferences';
import type { SaveTarget } from '@lino/protocol/generated/SaveTarget';
import type { SaveTicket } from '@lino/protocol/generated/SaveTicket';
import { sourceDocument } from '../transactions/line-endings.ts';
import { changeComposition, changeMode, compositionState, modeState, type EditorMode } from '../features/source-mode/state.ts';
import { markdownPresentation } from '../features/markdown/presentation.ts';
import { applyFormat, formatCommands, type FormatCommand } from '../features/markdown/commands.ts';
import { tableView } from '../features/tables/view.ts';
import { runTableCommand, tableCommands, tableControls, type TableCommand } from '../features/tables/commands.ts';
import { restoreCellFocus, tableCellFocus } from '../features/tables/state.ts';
import { documentSearch } from '../features/search/panel.ts';
import { runSearchCommand } from '../features/search/commands.ts';
import { replacementVisible } from '../features/search/commands.ts';
import { nativeSearchUI, searchProjection } from '../features/search/state.ts';
import { SearchQuery, getSearchQuery, setSearchQuery } from '@codemirror/search';
import { goToLine, lineNavigation } from '../features/navigation/line.ts';
import { editorLocalization } from '../localization/editor.ts';
import { t } from '../localization/index.ts';
import { editorTheme, preferredAppearance, themePreferences } from '../themes/editor.ts';
import { bodyFont, selectedTheme } from '../themes/catalog.ts';
import { codeLanguageForMarkdown } from '../features/code/languages.ts';
import { codeBlockAt, selectedCodeLines } from '../features/code/model.ts';
import { codeControls, runCodeCommand, setCodeClipboard, type WriteClipboard } from '../features/code/controls.ts';
import { codeOptions, changeCodeOptions } from '../features/code/state.ts';
import { codePresentation } from '../features/code/view.ts';
import { statistics } from '../features/analysis/model.ts';
import { nativeAnalysisView } from '../features/analysis/native.ts';
import { nativeAnalysisUI, analysisEmitter } from '../features/analysis/capabilities.ts';
import { documentAnalysis } from '../features/analysis/view.ts';
import { writingCommand, writingOptions, changeWriting } from '../features/writing/state.ts';
import { writingPresentation } from '../features/writing/view.ts';
import { zoomLayout } from '../features/writing/zoom.ts';
import { mathSyntax } from '../features/media/syntax.ts';
import { imageSizes, importAnchor, mediaContextChanged, setMediaHost } from '../features/media/state.ts';
import { mediaPresentation } from '../features/media/view.ts';
import { mediaControls, runMediaCommand } from '../features/media/controls.ts';
import { settleImports, prepareImageDrop, commitImageDrop, cancelImageDrop } from '../features/media/commands.ts';
import { referenceSyntax } from '../features/references/syntax.ts';
import { referenceIndex } from '../features/references/model.ts';
import { referenceControls } from '../features/references/state.ts';
import { referencePanels, runReferenceCommand } from '../features/references/controls.ts';
import { referencePresentation, referenceInteraction } from '../features/references/view.ts';
import { taskPresentation, toggleTasks } from '../features/markdown/tasks.ts';
import { localImageSources } from '../features/media/resources.ts';
import { contextualViewport } from '../controls/contextual.ts';
import { componentMenus } from '../controls/components.ts';
import { pointerPresentation } from '../controls/pointer.ts';
import '../controls/contextual.css';
import '../styles/motion.css';
import '../features/references/references.css';
import '../features/media/media.css';
import '../features/analysis/analysis.css';
import '../features/code/code.css';
import '../features/search/search.css';
import '../features/tables/tables.css';
import '../features/navigation/navigation.css';

export class MarkdownEditor {
  readonly view: EditorView;
  continueOutline(): void { this.view.plugin(nativeAnalysisView)?.resume(); }
  acceptsHeading(from: number, token: string): boolean {
    return Number.isInteger(from) && from >= 0 && from <= this.view.state.doc.length && !this.composing()
      && this.view.plugin(nativeAnalysisView)?.token === token;
  }

  private readonly source;
  private pendingMode: EditorMode | undefined;
  private disposed = false;
  private compositionGeneration = 0;
  private readonly writable = new Compartment();
  private frozen = false;
  private documentReadOnly = false;
  private readonly preferences = new Compartment();
  private preferenceGeneration = 0;
  private nativeOutlineSequence = 0n;
  private nativeQuerySequence = 0n;
  private readonly emit: (event: EditorHostEvent) => void;
  private readonly onChange: (docChanged: boolean) => void;
  private readonly assets: AssetPort | undefined;
  constructor(parent: HTMLElement, raw: string, emit: (event: EditorHostEvent) => void, onChange: (docChanged: boolean) => void = () => {}, writeClipboard?: WriteClipboard, assets?: AssetPort, capabilities: { nativeSearch?: boolean; nativeAnalysis?: boolean } = {}) {
    this.emit = emit; this.onChange = onChange; this.assets = assets;
    this.source = sourceDocument(raw);
    this.view = new EditorView({ parent, state: EditorState.create({
      doc: this.source.doc,
      extensions: [
        this.writable.of(EditorState.readOnly.of(false)), this.source.extension, history(),
        keymap.of([{ key: 'Mod-/', run: () => { this.command('toggle-source'); return true; }, preventDefault: true },
          { key: 'Tab', run: view => !!codeBlockAt(view.state) && runCodeCommand(view, 'code-indent'), shift: view => !!codeBlockAt(view.state) && runCodeCommand(view, 'code-outdent') },
          ...historyKeymap, ...defaultKeymap.filter(binding => binding.key !== 'Mod-/')]),
        this.preferences.of([Prec.high(keymap.of(markdownKeymap)), EditorView.contentAttributes.of({ spellcheck: 'false' })]),
        markdown({ base: markdownLanguage, addKeymap: false, codeLanguages: codeLanguageForMarkdown, extensions: [mathSyntax, referenceSyntax] }), editorTheme(),
        modeState, compositionState, pointerPresentation, editorLocalization(), contextualViewport, documentSearch, lineNavigation, tableControls, tableView, markdownPresentation,
        codeOptions, codeControls, codePresentation, importAnchor, imageSizes, mediaControls, mediaPresentation, writingOptions, zoomLayout(), capabilities.nativeAnalysis ? [statistics, nativeAnalysisUI.of(true), analysisEmitter.of(emit), nativeAnalysisView] : documentAnalysis, writingPresentation, EditorView.lineWrapping,
        referenceIndex, referenceControls, referencePanels, referencePresentation, referenceInteraction, taskPresentation,
        componentMenus.of((context, x, y, imageScale) => this.emit({ kind: 'context-menu', context, x, y, imageScale })),
        nativeSearchUI.of(!!capabilities.nativeSearch),
        EditorView.updateListener.of(update => { this.publish(); this.onChange(update.docChanged); }),
        EditorView.domEventHandlers({
          paste: (event, view) => {
            const image = Array.from(event.clipboardData?.items ?? []).some(item => item.kind === 'file' && item.type.startsWith('image/'));
            if (!image || view.state.readOnly || this.composing()) return false;
            event.preventDefault(); runMediaCommand(view, 'image-paste'); return true;
          },
          compositionstart: (_event, view) => {
            this.compositionGeneration++;
            view.dispatch({ effects: changeComposition.of(true) });
            return false;
          },
          compositionend: (_event, view) => {
            const generation = this.compositionGeneration;
            // CodeMirror queues its final DOM flush before user handlers.
            // Keep presentation frozen until that flush has consumed input.
            queueMicrotask(() => {
              if (!this.disposed && generation === this.compositionGeneration && !view.composing) view.dispatch({ effects: changeComposition.of(false) });
            });
            return false;
          },
        }),
      ],
    }) });
    if (writeClipboard) setCodeClipboard(this.view, writeClipboard);
    if (assets && writeClipboard) setMediaHost(this.view, { assets, copy: writeClipboard });
    this.publish();
  }
  read(): string { return this.source.read(this.view.state); }
  search(text: string, sequence?: string): void {
    if (sequence !== undefined) {
      if (!/^\d+$/.test(sequence)) throw new Error(t('editor.unknownCommand'));
      const next = BigInt(sequence); if (next <= this.nativeQuerySequence) return;
      this.nativeQuerySequence = next;
    }
    const previous = getSearchQuery(this.view.state);
    this.view.dispatch({ effects: setSearchQuery.of(new SearchQuery({ ...previous, search: text })) });
  }
  setOutlineVisible(visible: boolean, sequence: string): void {
    if (!/^\d+$/.test(sequence)) throw new Error(t('editor.unknownCommand'));
    const next = BigInt(sequence); if (next <= this.nativeOutlineSequence) return;
    this.nativeOutlineSequence = next;
    if (this.view.state.field(writingOptions).outline !== visible) this.view.dispatch({ effects: changeWriting.of({ outline: visible }) });
  }
  refreshResources(): void { this.view.dispatch({ effects: mediaContextChanged.of(null) }); }
  prepareImageDrop(x: number, y: number): boolean { return prepareImageDrop(this.view, x, y); }
  cancelImageDrop(): void { cancelImageDrop(this.view); }
  async commitImageDrop(paths: string[]): Promise<void> { await commitImageDrop(this.view, paths); }
  async settleResources(): Promise<void> { await settleImports(this.view); }
  async copySaveImages(ticket: SaveTicket, target: SaveTarget, raw: string): Promise<void> {
    const sources = localImageSources(raw);
    if (sources.length && this.assets) {
      const result = await this.assets.request('copy-save-images', JSON.stringify({ ticket_id: ticket.ticket_id, target, sources }));
      if (result !== 'copied') throw new Error(t('media.importCancelled'));
    }
  }
  async applyPreferences(values: EditorPreferences): Promise<void> {
    const generation = ++this.preferenceGeneration;
    await this.settleComposition();
    if (this.disposed || generation !== this.preferenceGeneration) return;
    const theme = selectedTheme(values);
    const size = values.use_theme_font_size ? theme.font_size : values.font_size;
    const height = values.use_theme_line_height ? theme.line_height : values.line_height;
    this.view.dispatch({ effects: [this.preferences.reconfigure([
      preferredAppearance.of(values.theme),
      themePreferences.of(values),
      ...(values.continue_lists ? [Prec.high(keymap.of(markdownKeymap))] : []),
      EditorView.contentAttributes.of({ spellcheck: String(values.spell_check) }),
      EditorView.theme({ '& > .cm-scroller > .cm-content': { fontFamily: bodyFont(values), fontSize: `calc(${size}px * var(--ot-editor-scale, 1))`, lineHeight: String(height / 100), maxWidth: values.content_width === 'fixed' ? `${values.page_width}px` : 'var(--ot-reading-width)' } }),
    ]), changeCodeOptions.of({ wrap: values.code_wrap, numbers: values.code_numbers })] });
  }
  composing(): boolean { return this.view.composing || this.view.state.field(compositionState); }
  canReplaceEmpty(): boolean {
    return this.view.state.doc.length === 0 && undoDepth(this.view.state) === 0 && redoDepth(this.view.state) === 0;
  }
  appearance(): 'light' | 'dark' { return this.view.state.facet(EditorView.darkTheme) ? 'dark' : 'light'; }
  setViewportWidth(width: number): void {
    if (!Number.isFinite(width) || width <= 0) return;
    if (this.view.dom.style.width === `${width}px`) return;
    this.view.dom.style.width = `${width}px`;
    this.view.dom.style.marginInline = 'auto';
    this.view.requestMeasure();
  }
  setReadOnly(value: boolean): void { this.frozen = value; this.updateReadOnly(); }
  setDocumentReadOnly(value: boolean): void { this.documentReadOnly = value; this.updateReadOnly(); }
  private updateReadOnly(): void { this.view.dispatch({ effects: this.writable.reconfigure(EditorState.readOnly.of(this.frozen || this.documentReadOnly)) }); }
  async settleComposition(): Promise<void> {
    const started = Date.now();
    while (this.composing()) {
      if (Date.now() - started > 10000) throw new Error(t('editor.finishComposition'));
      await new Promise(resolve => setTimeout(resolve, 20));
    }
  }
  snapshot() {
    return { text: this.source.read(this.view.state), selection: this.view.state.selection.toJSON(), ...this.status() };
  }
  status(): EditorStatus {
    const code = codeBlockAt(this.view.state);
    const writing = this.view.state.field(writingOptions);
    const codeView = this.view.state.field(codeOptions);
    return { ...writing, search: searchProjection(this.view.state, this.view.state.field(replacementVisible), String(this.nativeQuerySequence)), mode: this.view.state.field(modeState), composing: this.view.state.field(compositionState), pendingMode: this.pendingMode !== undefined,
      canUndo: !this.view.state.readOnly && undoDepth(this.view.state) > 0, canRedo: !this.view.state.readOnly && redoDepth(this.view.state) > 0,
      changedFromInitial: !this.view.state.doc.eq(this.source.doc), codeBlock: !!code, codeFenced: code?.fenced ?? false, codeWrap: codeView.wrap, codeNumbers: codeView.numbers,
      codeCanIndent: !this.view.state.readOnly && !!code && !!selectedCodeLines(this.view.state, code) };
  }
  private publish(): void {
    const composing = this.view?.state.field(compositionState) ?? false;
    if (this.pendingMode && !composing) {
      const next = this.pendingMode;
      this.pendingMode = undefined;
      // Never dispatch a second transaction from an update listener.
      queueMicrotask(() => { if (!this.disposed) this.command(next); });
    }
    if (this.view) this.emit({ kind: 'status', status: this.status() });
  }
  command(command: EditorCommand): boolean {
    if (command === 'toggle-source') {
      return this.command((this.pendingMode ?? this.view.state.field(modeState)) === 'source' ? 'visual' : 'source');
    }
    const composing = this.view.state.field(compositionState) || this.view.composing;
    if (composing) {
      if (command === 'visual' || command === 'source') this.pendingMode = command;
      this.emit({ kind: 'status', status: this.status() });
      return false;
    }
    if (command === 'find' || command === 'replace' || command === 'find-next' || command === 'find-previous' || command === 'toggle-find' || command === 'close-find') return runSearchCommand(this.view, command);
    if (writingCommand(this.view, command)) return true;
    if (command === 'goto-line') return goToLine(this.view);
    if (command === 'link' || (referenceCommands as readonly string[]).includes(command)) return runReferenceCommand(this.view, command as ReferenceCommand | 'link');
    if ((mediaCommands as readonly string[]).includes(command)) return runMediaCommand(this.view, command as MediaCommand);
    if ((codeCommands as readonly string[]).includes(command)) return runCodeCommand(this.view, command as CodeCommand);
    this.view.focus();
    if (command === 'visual' || command === 'source') {
      this.view.dispatch({ effects: [changeMode.of(command), this.view.scrollSnapshot()] });
      const focus = this.view.state.field(tableCellFocus, false);
      if (command === 'visual' && focus) restoreCellFocus(this.view, focus);
      return true;
    }
    if (this.view.state.readOnly) return false;
    if (command === 'indent' || command === 'outdent') return (command === 'indent' ? indentMore : indentLess)(this.view);
    if (command === 'toggle-task') {
      try { return toggleTasks(this.view); } catch (error) { this.emit({ kind: 'error', message: error instanceof Error ? error.message : String(error) }); return false; }
    }
    if ((formatCommands as readonly string[]).includes(command)) {
      try { return applyFormat(this.view, command as FormatCommand); }
      catch (error) { this.emit({ kind: 'error', message: error instanceof Error ? error.message : String(error) }); return false; }
    }
    if (command === 'undo' || command === 'redo') {
      const changed = (command === 'undo' ? undo : redo)(this.view);
      const focus = this.view.state.field(tableCellFocus, false);
      if (changed && focus) restoreCellFocus(this.view, focus);
      return changed;
    }
    if ((tableCommands as readonly string[]).includes(command)) {
      return runTableCommand(this.view, command as TableCommand, message => this.emit({ kind: 'error', message }));
    }
    return false;
  }
  select(anchor: number, head = anchor): void {
    this.view.dispatch({ selection: EditorSelection.single(anchor, head) });
  }
  destroy(): void { this.disposed = true; this.view.destroy(); }
}
