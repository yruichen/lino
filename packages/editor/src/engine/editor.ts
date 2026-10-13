import { Compartment, EditorSelection, EditorState } from '@codemirror/state';
import { defaultKeymap, history, historyKeymap, redo, redoDepth, undo, undoDepth } from '@codemirror/commands';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { EditorView, keymap } from '@codemirror/view';
import type { EditorCommand, EditorHostEvent, EditorStatus } from '@open-typora/protocol/editor-host';
import { sourceDocument } from '../transactions/line-endings.ts';
import { changeComposition, changeMode, compositionState, modeState, type EditorMode } from '../features/source-mode/state.ts';
import { markdownPresentation } from '../features/markdown/presentation.ts';
import { applyFormat, formatCommands, type FormatCommand } from '../features/markdown/commands.ts';
import { tableView } from '../features/tables/view.ts';
import { runTableCommand, tableCommands, tableControls, type TableCommand } from '../features/tables/commands.ts';
import { documentSearch } from '../features/search/panel.ts';
import { runSearchCommand } from '../features/search/commands.ts';
import { goToLine, lineNavigation } from '../features/navigation/line.ts';
import { editorLocalization } from '../localization/editor.ts';
import { t } from '../localization/index.ts';
import { editorTheme } from '../themes/editor.ts';
import '../features/search/search.css';
import '../features/tables/tables.css';
import '../features/navigation/navigation.css';

export class MarkdownEditor {
  readonly view: EditorView;
  private readonly source;
  private pendingMode: EditorMode | undefined;
  private disposed = false;
  private compositionGeneration = 0;
  private readonly writable = new Compartment();
  constructor(parent: HTMLElement, raw: string, private readonly emit: (event: EditorHostEvent) => void, private readonly onChange: (docChanged: boolean) => void = () => {}) {
    this.source = sourceDocument(raw);
    this.view = new EditorView({ parent, state: EditorState.create({
      doc: this.source.doc,
      extensions: [
        this.writable.of(EditorState.readOnly.of(false)), this.source.extension, history(),
        keymap.of([{ key: 'Mod-/', run: () => { this.command('toggle-source'); return true; }, preventDefault: true },
          ...historyKeymap, ...defaultKeymap.filter(binding => binding.key !== 'Mod-/')]),
        markdown({ base: markdownLanguage }), editorTheme(),
        modeState, compositionState, editorLocalization(), documentSearch, lineNavigation, tableControls, tableView, markdownPresentation, EditorView.lineWrapping,
        EditorView.contentAttributes.of({ spellcheck: 'false' }),
        EditorView.updateListener.of(update => { this.publish(); this.onChange(update.docChanged); }),
        EditorView.domEventHandlers({
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
    this.publish();
  }
  read(): string { return this.source.read(this.view.state); }
  composing(): boolean { return this.view.composing || this.view.state.field(compositionState); }
  setReadOnly(value: boolean): void { this.view.dispatch({ effects: this.writable.reconfigure(EditorState.readOnly.of(value)) }); }
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
    return { mode: this.view.state.field(modeState), composing: this.view.state.field(compositionState), pendingMode: this.pendingMode !== undefined,
      canUndo: !this.view.state.readOnly && undoDepth(this.view.state) > 0, canRedo: !this.view.state.readOnly && redoDepth(this.view.state) > 0,
      changedFromInitial: !this.view.state.doc.eq(this.source.doc) };
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
    if (command === 'find' || command === 'replace' || command === 'find-next' || command === 'find-previous') return runSearchCommand(this.view, command);
    if (command === 'goto-line') return goToLine(this.view);
    this.view.focus();
    if (command === 'visual' || command === 'source') {
      this.view.dispatch({ effects: [changeMode.of(command), this.view.scrollSnapshot()] });
      return true;
    }
    if (this.view.state.readOnly) return false;
    if ((formatCommands as readonly string[]).includes(command)) {
      try { return applyFormat(this.view, command as FormatCommand); }
      catch (error) { this.emit({ kind: 'error', message: error instanceof Error ? error.message : String(error) }); return false; }
    }
    if (command === 'undo' || command === 'redo') return (command === 'undo' ? undo : redo)(this.view);
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
