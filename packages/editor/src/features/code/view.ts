import { syntaxTree } from '@codemirror/language';
import { StateField, type EditorState } from '@codemirror/state';
import { Decoration, EditorView, ViewPlugin, WidgetType, type DecorationSet, type ViewUpdate } from '@codemirror/view';
import { codeBlockAt, codeBlockFromNode } from './model.ts';
import { codeOptions } from './state.ts';
import { modeState } from '../source-mode/state.ts';
import { runCodeCommand } from './controls.ts';
import { localeFacet } from '../../localization/editor.ts';
import { tFor } from '../../localization/index.ts';
import { componentMenu } from '../../controls/components.ts';

class LanguageWidget extends WidgetType {
  readonly bodyFrom: number; readonly language: string; readonly label: string; readonly plain: string;
  constructor(bodyFrom: number, language: string, label: string, plain: string) { super(); this.bodyFrom = bodyFrom; this.language = language; this.label = label; this.plain = plain; }
  override eq(other: LanguageWidget): boolean { return this.bodyFrom === other.bodyFrom && this.language === other.language && this.label === other.label && this.plain === other.plain; }
  override toDOM(view: EditorView): HTMLElement {
    const anchor = document.createElement('div'); anchor.className = 'ot-code-language-anchor'; anchor.dataset.codeBodyFrom = String(this.bodyFrom);
    const button = anchor.appendChild(document.createElement('button')); button.type = 'button'; button.className = 'ot-code-language';
    button.textContent = this.language || this.plain; button.setAttribute('aria-label', this.label);
    button.addEventListener('click', () => {
      if (view.composing) return;
      view.dispatch({ selection: { anchor: this.bodyFrom } }); runCodeCommand(view, 'code-language');
    }); return anchor;
  }
  override get estimatedHeight(): number { return 0; }
  override ignoreEvent(): boolean { return true; }
}
function decorate(state: EditorState): DecorationSet {
  const ranges: ReturnType<Decoration['range']>[] = [];
  if (state.field(modeState) !== 'visual') return Decoration.none;
  syntaxTree(state).iterate({ enter(node) {
    if (node.name !== 'FencedCode' && node.name !== 'CodeBlock') return ['Document', 'BulletList', 'OrderedList', 'ListItem', 'Blockquote'].includes(node.name) ? undefined : false;
    const block = codeBlockFromNode(state, node.node);
    if (block.fenced) {
      const locale = state.facet(localeFacet);
      // Remove the fence's line break too. The language badge is a zero-height
      // block anchor over the first body line, not a separate editable header.
      ranges.push(Decoration.replace({ block: true, inclusiveStart: true, inclusiveEnd: false, widget: new LanguageWidget(block.bodyFrom, block.language, tFor(locale, 'code.languageLabel'), tFor(locale, 'code.plain')) }).range(block.from, block.bodyFrom));
      const closing = node.node.getChildren('CodeMark').at(1);
      if (closing) {
        if (block.firstLine <= block.lastLine) ranges.push(Decoration.replace({ block: true, inclusiveStart: false, inclusiveEnd: true }).range(block.bodyTo - 1, block.to));
        else ranges.push(Decoration.replace({}).range(closing.from, closing.to));
      }
    }
    return false;
  } });
  return Decoration.set(ranges, true);
}
function visibleLines(view: EditorView): DecorationSet {
  const state = view.state, options = state.field(codeOptions), ranges: ReturnType<Decoration['range']>[] = [], seen = new Set<number>();
  for (const visible of view.visibleRanges) syntaxTree(state).iterate({ from: visible.from, to: visible.to, enter(node) {
    if (node.name !== 'FencedCode' && node.name !== 'CodeBlock') return;
    const block = codeBlockFromNode(state, node.node), framed = state.field(modeState) === 'visual';
    const start = block.firstLine;
    const end = framed ? Math.max(start, block.lastLine) : block.lastLine;
    const first = Math.max(start, state.doc.lineAt(visible.from).number), last = Math.min(end, state.doc.lineAt(visible.to).number);
    for (let number = first; number <= last && number <= state.doc.lines; number++) {
      const line = state.doc.line(number);
      if ((!framed && line.from >= block.bodyTo) || seen.has(line.from)) continue;
      seen.add(line.from);
      const body = number >= block.firstLine && number <= block.lastLine;
      ranges.push(Decoration.line({ attributes: {
        class: `ot-code-line${framed ? ' ot-code-framed' : ''}${framed && number === start ? ' ot-code-first' : ''}${framed && number === end ? ' ot-code-last' : ''}${options.wrap ? '' : ' ot-code-nowrap'}${options.numbers && body ? ' ot-code-numbered' : ''}`,
        ...(options.numbers && body ? { 'data-code-line': String(number - block.firstLine + 1) } : {}),
      } }).range(line.from));
    }
    return false;
  } });
  return Decoration.set(ranges, true);
}
const codeFences = StateField.define<DecorationSet>({
  create: decorate,
  update(value, tr) {
    return tr.docChanged || syntaxTree(tr.startState) !== syntaxTree(tr.state)
      || tr.startState.field(modeState) !== tr.state.field(modeState)
      || tr.startState.facet(localeFacet) !== tr.state.facet(localeFacet) ? decorate(tr.state) : value;
  },
  provide: field => [EditorView.decorations.from(field), EditorView.atomicRanges.of(view => view.state.field(field)),
    EditorView.domEventHandlers({ contextmenu: (event, view) => {
      const position = view.posAtCoords({ x: event.clientX, y: event.clientY });
      if (position === null || !codeBlockAt(view.state, position)) return false;
      view.dispatch({ selection: { anchor: position } }); view.focus(); componentMenu(view, 'code', event); return event.defaultPrevented;
    } })],
});
const codeLines = ViewPlugin.fromClass(class {
  decorations: DecorationSet;
  constructor(view: EditorView) { this.decorations = visibleLines(view); }
  update(update: ViewUpdate) {
    if (update.docChanged || update.viewportChanged || syntaxTree(update.startState) !== syntaxTree(update.state)
      || update.startState.field(codeOptions) !== update.state.field(codeOptions) || update.startState.field(modeState) !== update.state.field(modeState)) this.decorations = visibleLines(update.view);
  }
}, { decorations: value => value.decorations });
export const codePresentation = [codeFences, codeLines];
