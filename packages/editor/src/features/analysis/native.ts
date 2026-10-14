import { ViewPlugin, type ViewUpdate } from '@codemirror/view';
import { forceParsing, syntaxTree } from '@codemirror/language';
import { headings, selectionCounts, statistics } from './model.ts';
import { compositionState } from '../source-mode/state.ts';
// Capability lives separately from writing state to avoid a circular ownership path.
import { nativeAnalysisUI, analysisEmitter } from './capabilities.ts';
import { writingOptions } from '../writing/state.ts';
let nextInstance = 0;
export const nativeAnalysisView = ViewPlugin.fromClass(class {
  token = '';
  private instance = ++nextInstance;
  private sequence = 0;
  private publishedToken = '';
  resume(): void { this.attempts = 0; this.schedule(); }
  private timer?: ReturnType<typeof setTimeout>;
  private attempts = 0;
  private lastDoc?: import('@codemirror/state').Text;
  private lastTree?: ReturnType<typeof syntaxTree>;
  private result?: ReturnType<typeof headings>;
  private identities: (import('./model.ts').Heading & { id: string })[] = [];
  private nextHeading = 0;
  private disposed = false;
  private view: import('@codemirror/view').EditorView;
  constructor(view: import('@codemirror/view').EditorView) { this.view = view; this.schedule(); }
  update(update: ViewUpdate) {
    if (update.docChanged || syntaxTree(update.startState) !== syntaxTree(update.state)) { this.sequence++; this.token = ''; }
    if (update.docChanged) {
      this.attempts = 0;
      this.identities = this.identities.filter(entry => {
        let removed = false;
        update.changes.iterChangedRanges((from, to) => { if (from <= entry.from && to >= entry.to && to > from) removed = true; });
        return !removed;
      }).map(entry => ({ ...entry, from: update.changes.mapPos(entry.from, 1), to: update.changes.mapPos(entry.to, -1) }));
    }
    if (update.docChanged || update.selectionSet || syntaxTree(update.startState) !== syntaxTree(update.state)
      || update.startState.field(writingOptions) !== update.state.field(writingOptions)) this.schedule();
  }
  private schedule() {
    if (this.timer || this.disposed) return;
    this.timer = setTimeout(() => { this.timer = undefined; this.publish(); }, 50);
  }
  private publish() {
    if (this.disposed || !this.view.state.facet(nativeAnalysisUI)) return;
    const emit = this.view.state.facet(analysisEmitter), state = this.view.state;
    const selected = selectionCounts(state), counts = selected ?? state.field(statistics).total;
    emit?.({ kind: 'statistics', counts, selection: !!selected, visible: state.field(writingOptions).statistics });
    if (!state.field(writingOptions).outline) return;
    const tree = syntaxTree(state);
    if (!this.result || this.lastDoc !== state.doc || this.lastTree !== tree) { this.result = headings(state); this.lastDoc = state.doc; this.lastTree = tree; }
    const result = this.result;
    this.token = `${this.instance}:${this.sequence}`;
    const byLine = new Map(this.identities.map(entry => [state.doc.lineAt(Math.min(entry.from, state.doc.length)).from, entry.id]));
    const entries = result.entries.slice(0, 1000).map(entry => ({ ...entry, id: byLine.get(state.doc.lineAt(entry.from).from) ?? `${this.instance}:h${++this.nextHeading}` }));
    this.identities = result.complete ? entries : [...entries, ...this.identities.filter(previous => !entries.some(entry => entry.id === previous.id))];
    const current = entries.filter(entry => entry.from <= state.selection.main.head).at(-1)?.from ?? null;
    emit?.({ kind: 'outline', token: this.token, entries: this.token !== this.publishedToken ? entries : undefined, current, complete: result.complete, truncated: result.entries.length > 1000, exhausted: !result.complete && this.attempts >= 20 });
    this.publishedToken = this.token;
    if (!result.complete && this.attempts < 20) {
      if (this.view.composing || state.field(compositionState)) { this.schedule(); return; }
      this.attempts++;
      forceParsing(this.view, state.doc.length, 20); this.schedule();
    }
  }
  destroy() { this.disposed = true; if (this.timer) clearTimeout(this.timer); }
});
