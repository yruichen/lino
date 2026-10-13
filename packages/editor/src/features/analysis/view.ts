import { EditorSelection } from '@codemirror/state';
import { EditorView, ViewPlugin, showPanel, type Panel, type ViewUpdate } from '@codemirror/view';
import { forceParsing, syntaxTree } from '@codemirror/language';
import { localeFacet } from '../../localization/editor.ts';
import { tFor } from '../../localization/index.ts';
import { headings, selectionCounts, statistics } from './model.ts';
import { changeWriting, writingOptions } from '../writing/state.ts';
import { compositionState } from '../source-mode/state.ts';

function statsPanel(view: EditorView): Panel {
  const dom = document.createElement('div'); dom.className = 'ot-statistics';
  const output = dom.appendChild(document.createElement('output'));
  const update = () => {
    const selection = selectionCounts(view.state), counts = selection ?? view.state.field(statistics).total;
    output.textContent = tFor(view.state.facet(localeFacet), selection ? 'analysis.selection' : 'analysis.total', {
      words: counts.words, characters: counts.characters, lines: counts.lines, minutes: Math.ceil(counts.words / 250),
    });
    output.title = tFor(view.state.facet(localeFacet), 'analysis.countRules');
  };
  update(); return { dom, top: false, update };
}
const statisticsPanel = showPanel.from(writingOptions, value => value.statistics ? statsPanel : null);
export const outlineView = ViewPlugin.fromClass(class {
  private readonly dom = document.createElement('aside');
  private readonly input = document.createElement('input');
  private readonly list = document.createElement('div');
  private readonly title = document.createElement('strong');
  private readonly close = document.createElement('button');
  private readonly notice = document.createElement('output');
  private readonly resume = document.createElement('button');
  private view: EditorView;
  private collapsed = new Set<number>();
  private timer?: ReturnType<typeof setTimeout>;
  private disposed = false;
  private attempts = 0;
  constructor(view: EditorView) {
    this.view = view; this.dom.className = 'ot-document-outline';
    this.input.name = 'outline-filter'; this.input.type = 'search';
    this.close.type = 'button'; this.close.textContent = '×';
    this.close.addEventListener('click', () => { view.dispatch({ effects: changeWriting.of({ outline: false }) }); view.focus(); });
    this.resume.type = 'button'; this.resume.addEventListener('click', () => { this.attempts = 0; this.schedule(); this.render(); });
    this.input.addEventListener('input', () => this.render());
    this.dom.append(this.title, this.close, this.input, this.notice, this.resume, this.list);
    view.dom.append(this.dom); this.render(); this.schedule();
  }
  update(update: ViewUpdate) {
    if (update.docChanged) { this.collapsed.clear(); this.attempts = 0; }
    if (update.docChanged || update.selectionSet || syntaxTree(update.startState) !== syntaxTree(update.state)
        || update.startState.field(writingOptions) !== update.state.field(writingOptions)
        || update.startState.facet(localeFacet) !== update.state.facet(localeFacet)) this.render();
    if (update.docChanged) this.schedule();
    if (update.startState.field(writingOptions).outline !== update.state.field(writingOptions).outline) { this.attempts = 0; this.schedule(); }
  }
  private schedule() {
    if (this.timer || this.disposed || this.attempts >= 20 || !this.view.state.field(writingOptions).outline) return;
    this.timer = setTimeout(() => {
      this.timer = undefined;
      if (this.disposed) return;
      if (!this.view.state.field(writingOptions).outline) return;
      if (this.view.composing || this.view.state.field(compositionState)) { this.schedule(); return; }
      this.attempts++;
      const complete = forceParsing(this.view, this.view.state.doc.length, 20);
      this.render(); if (!complete) this.schedule();
    }, 100);
  }
  private render() {
    const state = this.view.state, locale = state.facet(localeFacet);
    this.dom.hidden = !state.field(writingOptions).outline;
    if (this.dom.hidden) return;
    this.title.textContent = tFor(locale, 'analysis.outline'); this.close.setAttribute('aria-label', tFor(locale, 'analysis.close'));
    this.input.setAttribute('aria-label', tFor(locale, 'analysis.filter')); this.input.placeholder = tFor(locale, 'analysis.filter');
    const result = headings(state), query = this.input.value.toLocaleLowerCase(locale);
    this.resume.hidden = result.complete || this.attempts < 20; this.resume.textContent = tFor(locale, 'analysis.continue');
    this.notice.textContent = !result.complete ? tFor(locale, this.attempts < 20 ? 'analysis.parsing' : 'analysis.parseLimit') : result.entries.length ? '' : tFor(locale, 'analysis.empty');
    this.list.replaceChildren();
    const current = result.entries.filter(entry => entry.from <= state.selection.main.head).at(-1);
    let hiddenBelow = 7;
    for (const entry of result.entries) {
      if (!query && entry.level > hiddenBelow) continue;
      hiddenBelow = 7;
      if (query && !entry.title.toLocaleLowerCase(locale).includes(query)) continue;
      if (this.list.childElementCount >= 1000) { this.notice.textContent = tFor(locale, 'analysis.limit'); break; }
      const row = document.createElement('div'); row.className = 'ot-outline-row'; row.style.paddingInlineStart = `${(entry.level - 1) * 10}px`;
      const fold = row.appendChild(document.createElement('button')); fold.type = 'button'; fold.textContent = this.collapsed.has(entry.from) ? '▸' : '▾';
      fold.setAttribute('aria-label', tFor(locale, 'analysis.fold')); fold.setAttribute('aria-expanded', String(!this.collapsed.has(entry.from)));
      fold.addEventListener('click', () => { if (this.collapsed.has(entry.from)) this.collapsed.delete(entry.from); else this.collapsed.add(entry.from); this.render(); });
      const button = row.appendChild(document.createElement('button')); button.type = 'button'; button.textContent = entry.title || tFor(locale, 'analysis.untitled');
      button.dataset.from = String(entry.from); button.setAttribute('aria-current', String(current === entry));
      const doc = state.doc;
      button.addEventListener('click', () => {
        if (this.view.state.doc !== doc || this.view.composing || this.view.state.field(compositionState)) return;
        this.view.dispatch({ selection: EditorSelection.cursor(entry.from), effects: EditorView.scrollIntoView(entry.from, { y: 'start' }) }); this.view.focus();
      });
      this.list.append(row); if (!query && this.collapsed.has(entry.from)) hiddenBelow = entry.level;
    }
  }
  destroy() { this.disposed = true; if (this.timer) clearTimeout(this.timer); this.dom.remove(); }
});
export const documentAnalysis = [statistics, statisticsPanel, outlineView];
