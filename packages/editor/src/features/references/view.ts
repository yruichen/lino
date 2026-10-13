import { StateField, type EditorState } from '@codemirror/state';
import { Decoration, EditorView, WidgetType, type DecorationSet } from '@codemirror/view';
import { localeFacet } from '../../localization/editor.ts';
import { tFor, type Locale } from '../../localization/index.ts';
import { compositionState, modeState } from '../source-mode/state.ts';
import { navigateSourcePosition } from '../navigation/line.ts';
import { referenceIndex, linkAt, type ReferenceIndex } from './model.ts';
import { openLink } from './commands.ts';
import { referenceReport } from './controls.ts';
import { presentationSelection, presentationSelectionChanged } from '../../controls/pointer.ts';

class TOCWidget extends WidgetType {
  readonly index: ReferenceIndex; readonly locale: Locale;
  constructor(index: ReferenceIndex, locale: Locale) { super(); this.index = index; this.locale = locale; }
  override eq(other: TOCWidget): boolean { return this.index === other.index && this.locale === other.locale; }
  toDOM(view: EditorView): HTMLElement {
    const dom = document.createElement('nav'); dom.className = 'ot-document-toc'; dom.setAttribute('aria-label', tFor(this.locale, 'references.toc'));
    const title = dom.appendChild(document.createElement('strong')); title.textContent = tFor(this.locale, 'references.toc');
    for (const heading of this.index.headings.slice(0, 1000)) {
      const button = dom.appendChild(document.createElement('button')); button.type = 'button'; button.textContent = heading.title;
      button.style.paddingInlineStart = `${(heading.level - 1) * 1.2}em`;
      button.addEventListener('click', () => {
        const current = view.state.field(referenceIndex).headings.find(item => item.anchor === heading.anchor);
        if (current) navigateSourcePosition(view, current.from);
      });
    }
    if (!this.index.headings.length) dom.append(document.createTextNode(tFor(this.locale, 'analysis.empty')));
    if (!this.index.complete || this.index.headings.length > 1000) dom.append(document.createTextNode(tFor(this.locale, 'references.partialTOC')));
    return dom;
  }
  override ignoreEvent(): boolean { return true; }
}
class FootnoteWidget extends WidgetType {
  readonly id: string; readonly number: number; readonly locale: Locale; readonly exists: boolean;
  constructor(id: string, number: number, locale: Locale, exists: boolean) { super(); this.id = id; this.number = number; this.locale = locale; this.exists = exists; }
  override eq(other: FootnoteWidget): boolean { return this.id === other.id && this.number === other.number && this.locale === other.locale && this.exists === other.exists; }
  toDOM(view: EditorView): HTMLElement {
    const dom = document.createElement('sup'); dom.className = 'ot-footnote-ref';
    const button = dom.appendChild(document.createElement('button')); button.type = 'button'; button.textContent = this.exists ? String(this.number) : `[^${this.id}]`;
    button.setAttribute('aria-label', `${tFor(this.locale, 'references.footnote')}: ${this.id}`);
    button.addEventListener('click', () => {
      const note = view.state.field(referenceIndex).notes.get(this.id);
      if (note) navigateSourcePosition(view, note.from); else referenceReport(view, new Error(tFor(this.locale, 'references.missingFootnote')));
    }); return dom;
  }
  override ignoreEvent(): boolean { return true; }
}
function build(state: EditorState): DecorationSet {
  if (state.field(modeState) === 'source' || state.field(compositionState)) return Decoration.none;
  const index = state.field(referenceIndex), locale = state.facet(localeFacet), ranges: ReturnType<Decoration['range']>[] = [];
  const active = (from: number, to: number) => presentationSelection(state).ranges.some(range => range.from <= to && range.to >= from);
  for (const link of index.links) {
    if (link.labelFrom < link.labelTo) ranges.push(Decoration.mark({ class: 'ot-document-link', attributes: { title: link.url } }).range(link.labelFrom, link.labelTo));
    if (!active(link.from, link.to)) {
      if (link.labelFrom > link.from) ranges.push(Decoration.replace({}).range(link.from, link.labelFrom));
      if (link.labelTo < link.to) ranges.push(Decoration.replace({}).range(link.labelTo, link.to));
    }
  }
  const numbers = new Map<string, number>();
  for (const mention of index.mentions) {
    if (!numbers.has(mention.id)) numbers.set(mention.id, numbers.size + 1);
    if (!active(mention.from, mention.to)) ranges.push(Decoration.replace({ widget: new FootnoteWidget(mention.id, numbers.get(mention.id)!, locale, index.notes.has(mention.id)) }).range(mention.from, mention.to));
  }
  for (const toc of index.toc) {
    const widget = new TOCWidget(index, locale);
    ranges.push(active(toc.from, toc.to) ? Decoration.widget({ widget, block: true, side: 1 }).range(toc.to) : Decoration.replace({ widget, block: true }).range(toc.from, toc.to));
  }
  return Decoration.set(ranges, true);
}
export const referencePresentation = StateField.define<DecorationSet>({
  create: build,
  update(value, tr) {
    return tr.docChanged || presentationSelectionChanged(tr.startState, tr.state) || tr.startState.field(referenceIndex) !== tr.state.field(referenceIndex)
      || tr.startState.field(modeState) !== tr.state.field(modeState) || tr.startState.field(compositionState) !== tr.state.field(compositionState)
      || tr.startState.facet(localeFacet) !== tr.state.facet(localeFacet) ? build(tr.state) : value;
  },
  provide: field => EditorView.decorations.from(field),
});
export const referenceInteraction = EditorView.domEventHandlers({ click(event, view) {
  if (!(event.metaKey || event.ctrlKey) || view.composing || view.state.field(compositionState)) return false;
  const position = view.posAtCoords({ x: event.clientX, y: event.clientY }); if (position === null) return false;
  const link = linkAt(view.state, position); if (!link) return false;
  event.preventDefault();
  try { return openLink(view, link.url, error => referenceReport(view, error)); }
  catch (error) { referenceReport(view, error); return true; }
} });
