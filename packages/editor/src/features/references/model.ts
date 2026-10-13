import { StateField, type EditorState } from '@codemirror/state';
import { syntaxTree, ensureSyntaxTree } from '@codemirror/language';
import { headings, type Heading } from '../analysis/model.ts';
import { markdownDestination, markdownUnescape, referenceKey, linkDefinitions, type LinkDefinition } from '../markdown/urls.ts';

type Node = ReturnType<typeof syntaxTree>['topNode'];
export interface DocumentLink { from: number; to: number; labelFrom: number; labelTo: number; label: string; rawLabel: string; url: string; title: string; definition?: LinkDefinition }
export interface Footnote { id: string; from: number; to: number; content: string }
export interface FootnoteReference { id: string; from: number; to: number }
export interface AnchoredHeading extends Heading { anchor: string }
export interface ReferenceIndex { links: DocumentLink[]; notes: Map<string, Footnote>; mentions: FootnoteReference[]; toc: { from: number; to: number }[]; headings: AnchoredHeading[]; complete: boolean }

// Lino anchor normalization is shared by document navigation and export. It is
// a declared local convention rather than a claim of every renderer's parity.
export function headingAnchor(text: string): string {
  return markdownUnescape(text).replace(/!\[([^\]]*)\]\([^)]*\)|\[([^\]]*)\]\([^)]*\)/g, '$1$2')
    .replace(/[`*_~^=]/g, '').trim().toLowerCase().replace(/[^\p{L}\p{N}_\-\s]/gu, '').replace(/\s/g, '-');
}
export function anchoredHeadings(entries: readonly Heading[]): AnchoredHeading[] {
  const used = new Set<string>();
  return entries.map(entry => {
    const base = headingAnchor(entry.title) || 'section'; let anchor = base, suffix = 0;
    while (used.has(anchor)) anchor = `${base}-${++suffix}`;
    used.add(anchor); return { ...entry, anchor };
  });
}
function parseLink(state: EditorState, node: Node, definitions: ReturnType<typeof linkDefinitions>): DocumentLink | undefined {
  if (node.name !== 'Link' && node.name !== 'Autolink' && node.name !== 'URL') return;
  if (node.name === 'URL') {
    if (node.parent?.name === 'Link' || node.parent?.name === 'Image' || node.parent?.name === 'LinkReference') return;
    const url = markdownDestination(state.sliceDoc(node.from, node.to));
    return { from: node.from, to: node.to, labelFrom: node.from, labelTo: node.to, rawLabel: url, label: url, url: /^www\./i.test(url) ? `https://${url}` : url, title: '' };
  }
  if (node.name === 'Autolink') {
    const label = state.sliceDoc(node.from + 1, node.to - 1);
    return { from: node.from, to: node.to, labelFrom: node.from + 1, labelTo: node.to - 1, label, rawLabel: label, url: label.includes('@') && !/^[a-z][a-z\d+.-]*:/i.test(label) ? `mailto:${label}` : label, title: '' };
  }
  const closing = node.getChildren('LinkMark').find(mark => state.sliceDoc(mark.from, mark.to) === ']');
  if (!closing) return;
  const rawLabel = state.sliceDoc(node.from + 1, closing.from), label = markdownUnescape(rawLabel);
  const url = node.getChild('URL'), key = node.getChild('LinkLabel'), title = node.getChild('LinkTitle');
  const definition = url ? undefined : definitions.get(referenceKey(key ? state.sliceDoc(key.from + 1, key.to - 1) : rawLabel));
  const destination = url ? markdownDestination(state.sliceDoc(url.from, url.to)) : definition?.url;
  if (destination === undefined) return;
  return { from: node.from, to: node.to, labelFrom: node.from + 1, labelTo: closing.from, rawLabel, label, url: destination,
    title: title ? markdownUnescape(state.sliceDoc(title.from + 1, title.to - 1)) : definition?.title ?? '', definition };
}
export function references(state: EditorState): ReferenceIndex {
  const result: ReferenceIndex = { links: [], notes: new Map(), mentions: [], toc: [], headings: [], complete: false };
  const definitions = linkDefinitions(state), outline = headings(state);
  result.headings = anchoredHeadings(outline.entries); result.complete = outline.complete;
  syntaxTree(state).iterate({ enter(node) {
    if (['FencedCode', 'CodeBlock', 'InlineCode', 'InlineMath', 'MathBlock', 'FrontMatter', 'HTMLBlock', 'Image'].includes(node.name)) return false;
    if (node.name === 'FootnoteDefinition') {
      const label = node.node.getChild('FootnoteLabel'); if (!label) return false;
      const id = state.sliceDoc(label.from + 2, label.to - 1);
      if (!result.notes.has(id)) result.notes.set(id, { id, from: node.from, to: node.to, content: state.sliceDoc(label.to, node.to).replace(/^:[ \t]*/, '') });
      return false;
    }
    if (node.name === 'FootnoteReference') { result.mentions.push({ id: state.sliceDoc(node.from + 2, node.to - 1), from: node.from, to: node.to }); return false; }
    if (node.name === 'DocumentTOC') { result.toc.push({ from: node.from, to: node.to }); return false; }
    const link = parseLink(state, node.node, definitions);
    if (link) { result.links.push(link); return false; }
  } });
  return result;
}
export const referenceIndex = StateField.define<ReferenceIndex>({
  create: references,
  update(value, tr) { return tr.docChanged || syntaxTree(tr.startState) !== syntaxTree(tr.state) ? references(tr.state) : value; },
});
export function linkAt(state: EditorState, pos = state.selection.main.head): DocumentLink | undefined {
  const tree = ensureSyntaxTree(state, pos, 30); if (!tree) return;
  const definitions = linkDefinitions(state);
  for (const side of [1, -1] as const) for (let node: Node | null = tree.resolve(pos, side); node; node = node.parent) {
    if (['Image', 'InlineCode', 'FencedCode', 'MathBlock', 'InlineMath'].includes(node.name)) break;
    const link = parseLink(state, node, definitions); if (link) return link;
  }
}
