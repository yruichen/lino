import { SearchQuery, getSearchQuery, search, setSearchQuery } from '@codemirror/search';
import { keymap, type EditorView, type Panel, type ViewUpdate } from '@codemirror/view';
import { canReplace, closeSearchPanel, MATCH_LIMIT, replacementTransactions, replacementVisible, replaceMatches, runSearchCommand, searchMatches, showReplacement, type SearchMatches } from './commands.ts';
import { localeFacet } from '../../localization/editor.ts';
import { formatNumber, tFor, type Locale, type MessageArguments, type MessageKey } from '../../localization/index.ts';
import { nativeSearchUI, querySummary } from './state.ts';
import { searchArrival, searchMotion } from './motion.ts';

class SearchPanel implements Panel {
  readonly dom = document.createElement('section');
  readonly top = true;
  private readonly find = this.input('search');
  private readonly replacement = this.input('replace');
  private readonly matchCase = this.option('case');
  private readonly wholeWord = this.option('word');
  private readonly regexp = this.option('regexp');
  private readonly result = document.createElement('output');
  private readonly replacementRow = document.createElement('div');
  private readonly next: HTMLButtonElement;
  private readonly previous: HTMLButtonElement;
  private readonly replace: HTMLButtonElement;
  private readonly replaceAll: HTMLButtonElement;
  private readonly toggle: HTMLButtonElement;
  private readonly close: HTMLButtonElement;
  private readonly help = document.createElement('span');
  private readonly optionsToggle: HTMLButtonElement;
  private locale: Locale;
  private matches: SearchMatches = { ranges: [], overflow: false };
  private query: SearchQuery;
  private readonly view: EditorView;
  constructor(view: EditorView) {
    this.view = view;
    this.query = getSearchQuery(view.state);
    this.locale = view.state.facet(localeFacet);
    this.dom.className = 'ot-search';
    const row = this.dom.appendChild(document.createElement('div'));
    row.className = 'ot-search-row';
    const native = view.state.facet(nativeSearchUI);
    this.dom.dataset.native = String(native); this.find.hidden = native;
    if (!native) this.find.setAttribute('main-field', 'true');
    this.toggle = this.button('toggle-replace', () => view.dispatch({ effects: showReplacement.of(!view.state.field(replacementVisible)) }));
    this.previous = this.button('previous', () => this.navigate(true));
    this.next = this.button('next', () => this.navigate(false));
    this.close = this.button('close', () => closeSearchPanel(view));
    this.result.className = 'ot-search-result';
    this.result.setAttribute('aria-live', 'polite');
    row.append(this.find, this.result, this.previous, this.next, this.toggle, this.close);
    const options = this.dom.appendChild(document.createElement('div'));
    options.className = 'ot-search-options';
    options.hidden = native;
    this.optionsToggle = this.button('options', () => { options.hidden = !options.hidden; this.optionsToggle.setAttribute('aria-expanded', String(!options.hidden)); });
    this.optionsToggle.hidden = !native; this.optionsToggle.setAttribute('aria-expanded', String(!options.hidden));
    row.insertBefore(this.optionsToggle, this.close);
    options.append(this.matchCase.label, this.wholeWord.label, this.regexp.label);
    options.append(this.help); this.help.className = 'ot-search-help';
    this.replacementRow.className = 'ot-search-row';
    this.replace = this.button('replace-current', () => this.replaceSelection(false));
    this.replaceAll = this.button('replace-all', () => this.replaceSelection(true));
    this.replacementRow.append(this.replacement, this.replace, this.replaceAll);
    this.dom.append(this.replacementRow);
    this.dom.addEventListener('keydown', event => {
      if (event.isComposing || event.keyCode === 229) return;
      if (event.key === 'Escape') { event.preventDefault(); closeSearchPanel(view); }
      else if (event.key === 'Enter' && (event.target === this.find || event.target === this.replacement)) {
        event.preventDefault();
        if (event.target === this.replacement) this.replaceSelection(false);
        else this.navigate(event.shiftKey);
      }
    });
    this.localize(); this.sync();
    this.recount();
  }
  private input(name: string): HTMLInputElement {
    const input = document.createElement('input');
    input.type = 'text'; input.name = name; input.className = 'ot-search-input';
    input.autocomplete = 'off'; input.spellcheck = false;
    input.addEventListener('input', event => { if (!(event as InputEvent).isComposing) this.commit(); });
    input.addEventListener('compositionend', () => this.commit());
    return input;
  }
  private option(name: string) {
    const label = document.createElement('label'), input = document.createElement('input'), text = document.createTextNode('');
    input.type = 'checkbox'; input.name = name;
    label.append(input, text);
    input.addEventListener('change', () => this.commit());
    return { input, label, text };
  }
  private button(name: string, action: () => unknown): HTMLButtonElement {
    const button = document.createElement('button');
    button.type = 'button'; button.name = name;
    button.addEventListener('click', () => action());
    return button;
  }
  private localize(): void {
    const tr = <K extends MessageKey>(key: K, ...args: MessageArguments<K>) => tFor(this.locale, key, ...args);
    this.dom.setAttribute('aria-label', tr('search.label'));
    this.find.setAttribute('aria-label', tr('search.find')); this.find.placeholder = tr('search.findPlaceholder');
    this.replacement.setAttribute('aria-label', tr('search.replaceWith')); this.replacement.placeholder = tr('search.replacePlaceholder');
    for (const [option, text, title] of [
      [this.matchCase, 'Aa', tr('search.case')], [this.wholeWord, tr('search.wordShort'), tr('search.word')],
      [this.regexp, '.*', tr('search.regexp')],
    ] as const) { option.text.nodeValue = text; option.label.title = title; option.input.setAttribute('aria-label', title); }
    for (const [button, text, title] of [
      [this.toggle, tr('search.replace'), tr('search.replace')], [this.previous, '↑', tr('search.previous')],
      [this.next, '↓', tr('search.next')], [this.close, tr('search.done'), tr('search.close')],
      [this.replace, tr('search.replaceCurrent'), tr('search.replaceCurrent')],
      [this.replaceAll, tr('search.replaceAll'), tr('search.replaceAllHelp')],
    ] as const) { button.textContent = text; button.title = title; button.setAttribute('aria-label', title); }
    this.help.textContent = tr('search.help');
    this.optionsToggle.textContent = tr('search.options'); this.optionsToggle.setAttribute('aria-label', tr('search.options'));
  }
  private commit(): void {
    const query = new SearchQuery({ search: this.find.value, replace: this.replacement.value,
      caseSensitive: this.matchCase.input.checked, wholeWord: this.wholeWord.input.checked, regexp: this.regexp.input.checked });
    if (!query.eq(this.query)) this.view.dispatch({ effects: setSearchQuery.of(query) });
  }
  private sync(): void {
    this.find.value = this.query.search; this.replacement.value = this.query.replace;
    this.matchCase.input.checked = this.query.caseSensitive;
    this.wholeWord.input.checked = this.query.wholeWord;
    this.regexp.input.checked = this.query.regexp;
  }
  private recount(): void { this.matches = searchMatches(this.view.state); this.render(); }
  private render(): void {
    const invalid = !!this.query.search && !this.query.valid;
    const selection = this.view.state.selection.main;
    const selected = this.matches.ranges.findIndex(range => range.from === selection.from && range.to === selection.to);
    const count = formatNumber(this.locale, this.matches.ranges.length) + (this.matches.overflow ? '+' : '');
    this.result.textContent = invalid ? tFor(this.locale, 'search.invalid') : !this.query.search ? tFor(this.locale, 'search.empty') :
      selected >= 0 ? tFor(this.locale, 'search.selectedMatch', {index: selected + 1, count}) : tFor(this.locale, 'search.matches', {count});
    this.result.classList.toggle('is-error', invalid);
    this.result.dataset.current = String(selected >= 0);
    this.find.setAttribute('aria-invalid', String(invalid));
    const visible = this.view.state.field(replacementVisible);
    this.replacementRow.hidden = !visible; this.toggle.setAttribute('aria-pressed', String(visible));
    const writable = canReplace(this.view.state, this.view.composing);
    this.replacement.disabled = !writable;
    this.next.disabled = this.previous.disabled = !this.query.valid || !this.matches.ranges.length;
    this.replace.disabled = !writable || !this.query.valid || !this.matches.ranges.length;
    this.replaceAll.disabled = this.replace.disabled || this.matches.overflow;
    this.replaceAll.title = this.matches.overflow ? tFor(this.locale, 'search.limit', {limit: MATCH_LIMIT}) : tFor(this.locale, 'search.replaceAllHelp');
    this.replaceAll.setAttribute('aria-label', this.replaceAll.title);
  }
  private navigate(previous: boolean): void {
    if (this.query.valid) runSearchCommand(this.view, previous ? 'find-previous' : 'find-next');
  }
  private replaceSelection(all: boolean): void {
    replaceMatches(this.view, all);
    this.render();
  }
  mount(): void { if (!this.view.state.facet(nativeSearchUI)) { this.find.focus(); this.find.select(); } }
  update(update: ViewUpdate): void {
    const locale = update.state.facet(localeFacet);
    if (locale !== this.locale) { this.locale = locale; this.localize(); }
    const query = getSearchQuery(update.state), changed = !query.eq(this.query);
    if (changed) { this.query = query; this.sync(); }
    if (changed || update.docChanged) this.recount();
    else this.render();
  }
}

export const documentSearch = [
  search({ top: true, createPanel: view => new SearchPanel(view), scrollToMatch: range => searchArrival.of(range) }), querySummary, searchMotion, replacementVisible, replacementTransactions,
  keymap.of([
    { key: 'Mod-f', run: view => runSearchCommand(view, 'find') },
    { key: 'Mod-Alt-f', run: view => runSearchCommand(view, 'replace') },
    { key: 'Mod-g', run: view => runSearchCommand(view, 'find-next'), shift: view => runSearchCommand(view, 'find-previous') },
    { key: 'F3', run: view => runSearchCommand(view, 'find-next'), shift: view => runSearchCommand(view, 'find-previous') },
    { key: 'Escape', run: closeSearchPanel },
  ]),
];
