import { ensureSyntaxTree, syntaxTree } from '@codemirror/language';
import { countColumn, type EditorState, type Line } from '@codemirror/state';
import { MAX_CLIPBOARD_CHARACTERS } from '@lino/protocol/clipboard';
type SyntaxNode = ReturnType<typeof syntaxTree>['topNode'];

export type CodeErrorCode = 'selectBlock' | 'language' | 'indentedLanguage' | 'selection' | 'limit' | 'copyLimit' | 'clipboard';
export class CodeError extends Error {
  readonly code: CodeErrorCode;
  constructor(code: CodeErrorCode) { super(code); this.code = code; }
}
export interface CodeBlock {
  from: number; to: number; fenced: boolean;
  language: string; languageFrom: number; languageTo: number;
  bodyFrom: number; bodyTo: number; firstLine: number; lastLine: number;
  fenceIndent: number;
  textRanges: readonly { from: number; to: number }[];
}
export function codeBlockFromNode(state: EditorState, node: SyntaxNode): CodeBlock {
  const fenced = node.name === 'FencedCode';
  const opening = state.doc.lineAt(node.from), info = node.getChild('CodeInfo');
  const marks = node.getChildren('CodeMark');
  const closing = fenced && marks.length > 1 ? state.doc.lineAt(marks.at(-1)!.from) : undefined;
  const infoText = info ? state.doc.sliceString(info.from, info.to) : '';
  const token = /^\S*/.exec(infoText)![0];
  const languageFrom = info?.from ?? marks[0]?.to ?? node.from;
  const prefix = state.doc.sliceString(opening.from, node.from);
  let fenceIndent = countColumn(prefix, state.tabSize);
  const quote = prefix.lastIndexOf('>');
  if (quote >= 0) fenceIndent = countColumn(prefix.slice(quote + 1).replace(/^[ \t]/, ''), state.tabSize);
  else {
    for (let parent = node.parent; parent; parent = parent.parent) {
      if (parent.name !== 'ListItem') continue;
      const mark = parent.getChild('ListMark');
      if (mark) {
        const line = state.doc.lineAt(mark.to);
        const suffix = state.doc.sliceString(mark.to, line.to);
        const padding = /^[ \t]+/.exec(suffix)?.[0] ?? '';
        const base = state.doc.sliceString(line.from, mark.to) + padding;
        fenceIndent = Math.max(0, fenceIndent - countColumn(base, state.tabSize));
      }
      break;
    }
  }
  if (!/^[ \t]*$/.test(prefix) && quote < 0 && !/^[ \t]*([-+*]|\d+[.)])[ \t]+$/.test(prefix)) fenceIndent = 0;
  const bodyFrom = fenced ? Math.min(opening.to + 1, state.doc.length) : opening.from;
  const bodyTo = closing?.from ?? node.to;
  return {
    from: node.from, to: node.to, fenced, language: token, languageFrom, languageTo: languageFrom + token.length,
    bodyFrom, bodyTo, firstLine: fenced ? opening.number + 1 : opening.number,
    lastLine: closing ? closing.number - 1 : state.doc.lineAt(node.to).number,
    fenceIndent: fenced ? Math.min(3, fenceIndent) : 0,
    textRanges: node.getChildren('CodeText').map(text => ({ from: text.from, to: text.to })),
  };
}
export function codeBlockAt(state: EditorState, position = state.selection.main.head): CodeBlock | undefined {
  const tree = ensureSyntaxTree(state, position, 50);
  if (!tree) return undefined;
  for (const side of [1, -1] as const) for (let node: SyntaxNode | null = tree.resolve(position, side); node; node = node.parent) {
    if (node.name === 'FencedCode' || node.name === 'CodeBlock') return codeBlockFromNode(state, node);
  }
  return undefined;
}
/** Exclude container markers, while keeping the user's actual code indentation. */
export function codeLineStart(block: CodeBlock, line: Line): number {
  let low = 0, high = block.textRanges.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if (block.textRanges[middle].to <= line.from) low = middle + 1; else high = middle;
  }
  const range = block.textRanges[low];
  return range && range.from <= line.to ? Math.max(line.from, range.from) : line.to;
}
function stripFenceIndent(text: string, width: number, tabSize: number): string {
  let column = 0, index = 0;
  while (index < text.length && column < width && (text[index] === ' ' || text[index] === '\t')) {
    column += text[index++] === '\t' ? tabSize - column % tabSize : 1;
  }
  return ' '.repeat(Math.max(0, column - width)) + text.slice(index);
}
export function codeContents(state: EditorState, block: CodeBlock): string {
  const parts: string[] = [];
  let length = 0;
  for (let number = block.firstLine; number <= block.lastLine && number <= state.doc.lines; number++) {
    const line = state.doc.line(number);
    if (line.from >= block.bodyTo) break;
    const from = codeLineStart(block, line), to = Math.min(line.to, block.bodyTo);
    if (to - from > MAX_CLIPBOARD_CHARACTERS - length + block.fenceIndent) throw new CodeError('copyLimit');
    const text = stripFenceIndent(state.doc.sliceString(from, to), block.fenceIndent, state.tabSize);
    length += text.length + (line.to < block.bodyTo ? 1 : 0);
    if (length > MAX_CLIPBOARD_CHARACTERS) throw new CodeError('copyLimit');
    parts.push(text);
    if (line.to < block.bodyTo) parts.push('\n');
  }
  return parts.join('');
}
export function selectedCodeLines(state: EditorState, block: CodeBlock): { first: number; last: number } | undefined {
  const range = state.selection.main;
  if (state.selection.ranges.length !== 1 || range.from < block.bodyFrom || range.to > block.bodyTo) return undefined;
  const first = state.doc.lineAt(range.from).number, end = state.doc.lineAt(range.to);
  const last = range.to === end.from && !range.empty ? end.number - 1 : end.number;
  return first >= block.firstLine && last <= block.lastLine ? { first, last } : undefined;
}
