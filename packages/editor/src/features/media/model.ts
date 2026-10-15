import { syntaxTree, ensureSyntaxTree } from '@codemirror/language';
import type { EditorState } from '@codemirror/state';
import { t } from '../../localization/index.ts';
import { codeBlockFromNode, codeContents } from '../code/model.ts';
import { MAX_PREVIEW_TEXT } from '../../renderers/previews.ts';
import { markdownUnescape as unescape, markdownDestination as destination, linkDefinitions as references, referenceKey, escapedLabel, escapedDestination, escapedTitle } from '../markdown/urls.ts';

export interface PreviewSource { kind: 'image' | 'math' | 'diagram'; from: number; to: number; block: boolean; text: string; tooLarge?: boolean; alt?: string; title?: string; caption?: string; reference?: boolean }
type Node = ReturnType<typeof syntaxTree>['topNode'];
export function sourceNode(state: EditorState, node: Node, refs?: ReturnType<typeof references>): PreviewSource | undefined {
  if (node.name === 'InlineMath' || node.name === 'MathBlock') {
    const block = node.name === 'MathBlock', marks = node.getChildren('MathMark');
    if (marks.length !== 2) return undefined;
    const from = block ? Math.min(state.doc.lineAt(marks[0].to).to + 1, state.doc.length) : marks[0].to;
    const to = block ? state.doc.lineAt(marks[1].from).from : marks[1].from;
    return { kind: 'math', from: node.from, to: node.to, block, tooLarge: to - from > MAX_PREVIEW_TEXT, text: state.sliceDoc(from, Math.min(to, from + MAX_PREVIEW_TEXT + 1)).replace(/\n$/, '') };
  }
  if (node.name === 'FencedCode') {
    const code = codeBlockFromNode(state, node);
    if (code.language.toLowerCase() === 'mermaid') {
      const tooLarge = code.bodyTo - code.bodyFrom > MAX_PREVIEW_TEXT;
      return { kind: 'diagram', from: node.from, to: node.to, block: true, tooLarge, text: tooLarge ? state.sliceDoc(code.bodyFrom, Math.min(code.bodyTo, code.bodyFrom + MAX_PREVIEW_TEXT + 1)) : codeContents(state, code) };
    }
  }
  if (node.name !== 'Image') return undefined;
  const marks = node.getChildren('LinkMark'), url = node.getChild('URL'), label = node.getChild('LinkLabel'), title = node.getChild('LinkTitle');
  const closing = marks.find(mark => state.sliceDoc(mark.from, mark.to) === ']');
  if (!closing) return undefined;
  const altSource = state.sliceDoc(node.from + 2, closing.from), alt = unescape(altSource);
  const ref = url ? undefined : (refs ?? references(state)).get(referenceKey(label ? state.sliceDoc(label.from + 1, label.to - 1) : alt));
  const text = url ? destination(state.sliceDoc(url.from, url.to)) : ref?.url;
  if (text === undefined) return undefined;
  const titleSource = title ? state.sliceDoc(title.from + 1, title.to - 1) : ref?.titleSource;
  return { kind: 'image', from: node.from, to: node.to, block: false, text, alt, title: titleSource === undefined ? undefined : unescape(titleSource), caption: titleSource || altSource, reference: !url };
}
export function previewSources(state: EditorState): PreviewSource[] {
  const items: PreviewSource[] = [], refs = references(state);
  syntaxTree(state).iterate({ enter(node) {
    if (node.name === 'Table' || node.name === 'HTMLBlock') return false;
    const item = sourceNode(state, node.node, refs);
    if (item) { items.push(item); return false; }
  } }); return items;
}
export function previewAt(state: EditorState, pos = state.selection.main.head): PreviewSource | undefined {
  const tree = ensureSyntaxTree(state, pos, 30);
  if (!tree) return undefined;
  for (const side of [1, -1] as const) for (let node: Node | null = tree.resolve(pos, side); node; node = node.parent) {
    const source = sourceNode(state, node); if (source) return source;
  }
  return undefined;
}
export function imageMarkdown(source: string, alt: string, title = ''): string {
  if (!source || /[\r\n\0]/.test(source + alt + title)) throw new Error(t('media.invalidProperties'));
  return `![${escapedLabel(alt)}](<${escapedDestination(source)}>${title ? ` "${escapedTitle(title)}"` : ''})`;
}
export function importedSource(path: string): string { return path.split('/').map(encodeURIComponent).join('/'); }
