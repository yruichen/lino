import { localizeError } from '../../localization/index.ts';
import { ensureSyntaxTree, syntaxTree } from '@codemirror/language';
import type { EditorState } from '@codemirror/state';

export type MarkdownNode = ReturnType<typeof syntaxTree>['topNode'];
export function selectedLines(state: EditorState) {
  const range = state.selection.main;
  const first = state.doc.lineAt(range.from);
  const last = state.doc.lineAt(range.to > range.from && state.doc.lineAt(range.to).from === range.to ? range.to - 1 : range.to);
  const count = last.number - first.number + 1;
  if (count > 10000) throw localizeError(new Error(), 'format.lineLimit', {limit: 10000});
  return Array.from({ length: count }, (_, index) => state.doc.line(first.number + index));
}
export function selectionTree(state: EditorState) {
  if (state.selection.ranges.length !== 1) throw localizeError(new Error(), 'format.singleSelection');
  const range = state.selection.main;
  for (const position of [range.from, range.to]) {
    const before = state.doc.sliceString(Math.max(0, position - 1), position).charCodeAt(0);
    const after = state.doc.sliceString(position, position + 1).charCodeAt(0);
    if (before >= 0xd800 && before <= 0xdbff && after >= 0xdc00 && after <= 0xdfff) throw localizeError(new Error(), 'format.unicodeBoundary');
  }
  const tree = ensureSyntaxTree(state, selectedLines(state).at(-1)!.to, 50);
  if (!tree) throw localizeError(new Error(), 'format.parsing');
  return tree;
}
export function enclosingNode(state: EditorState, names: readonly string[]): MarkdownNode | undefined {
  const range = state.selection.main;
  let found: MarkdownNode | undefined;
  selectionTree(state).iterate({ from: range.from, to: range.to, enter(node) {
    if (names.includes(node.name) && node.from <= range.from && node.to >= range.to) found = node.node;
  } });
  return found;
}
export function guardTextBlocks(state: EditorState, allowFences = false): void {
  const lines = selectedLines(state);
  selectionTree(state).iterate({ from: lines[0].from, to: lines.at(-1)!.to, enter(node) {
    if (['Table', 'HTMLBlock', 'CodeBlock'].includes(node.name) || (!allowFences && node.name === 'FencedCode')) {
      throw localizeError(new Error(), 'format.textOnly');
    }
  } });
}
