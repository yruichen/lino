import type { ChangeSpec, EditorState, TransactionSpec } from '@codemirror/state';
import { inlineNodeNames } from './inline.ts';
import { guardTextBlocks, selectionTree } from './selection.ts';
import { t } from '../../localization/index.ts';

/** Remove parsed inline wrappers, never regex-strip literal document text. */
export function clearInlineFormatting(state: EditorState): TransactionSpec {
  guardTextBlocks(state);
  const range = state.selection.main, names = new Set([...Object.values(inlineNodeNames), 'Link']);
  const intervals: { from: number; to: number }[] = [];
  selectionTree(state).iterate({ from: range.from, to: range.to, enter(node) {
    if (!names.has(node.name)) return;
    const opening = node.node.firstChild, closing = node.node.lastChild;
    if (!opening || !closing) return;
    const end = node.name === 'Link' ? node.node.getChildren('LinkMark').find(mark => state.sliceDoc(mark.from, mark.to) === ']')?.from : closing.from;
    const start = node.name === 'Link' ? node.from + 1 : opening.to;
    if (end === undefined) return;
    const contained = range.from <= node.from && range.to >= node.to;
    const body = range.from === start && range.to === end;
    if (!range.empty && !contained && !body) throw new Error(t('format.unwrap'));
    if (node.name === 'InlineCode') {
      const text = state.sliceDoc(start, end), padding = text.startsWith(' ') && text.endsWith(' ') && /[^ ]/.test(text) ? 1 : 0;
      intervals.push({ from: node.from, to: start + padding }, { from: end - padding, to: node.to });
    } else intervals.push({ from: node.from, to: start }, { from: end, to: node.to });
  } });
  intervals.sort((a, b) => a.from - b.from);
  const merged: { from: number; to: number }[] = [];
  for (const interval of intervals) {
    const previous = merged.at(-1);
    if (previous && previous.to >= interval.from) previous.to = Math.max(previous.to, interval.to);
    else merged.push({ ...interval });
  }
  const changes = state.changes(merged as ChangeSpec[]);
  return { changes, selection: state.selection.map(changes, 1) };
}
