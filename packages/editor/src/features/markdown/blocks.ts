import { localizeError } from '../../localization/index.ts';
import { EditorSelection, type ChangeSpec, type EditorState, type TransactionSpec } from '@codemirror/state';
import { enclosingNode, guardTextBlocks, selectedLines, selectionTree } from './selection.ts';

export type BlockFormat = `heading-${1 | 2 | 3 | 4 | 5 | 6}` | 'bullet-list' | 'ordered-list' | 'task-list' | 'blockquote' | 'code-block';
function prefix(text: string) {
  const outer = /^(?:[ \t]*(?:>[ \t]?))*/.exec(text)![0];
  const rest = text.slice(outer.length), indent = /^[ \t]*/.exec(rest)![0];
  const start = outer.length + indent.length;
  const list = /^(?:([-+*])|(\d{1,9}[.)]))(?:[ \t]+|$)(\[[ xX]\](?:[ \t]+|$))?/.exec(text.slice(start));
  const content = start + (list?.[0].length ?? 0);
  return { outer, start, list, content };
}
function mapped(state: EditorState, changes: ChangeSpec[]): TransactionSpec {
  const changeSet = state.changes(changes);
  // A collapsed caret at a block's prefix boundary belongs to its content.
  // CM's default association (-1) would leave it before a newly inserted marker.
  // Non-empty ranges keep CM's normal content-preserving endpoint mapping.
  return { changes: changeSet, selection: state.selection.map(changeSet, 1) };
}
function headings(state: EditorState, level: number): TransactionSpec {
  const lines = selectedLines(state);
  selectionTree(state).iterate({ from: lines[0].from, to: lines.at(-1)!.to, enter(node) {
    if (node.name.startsWith('SetextHeading')) throw localizeError(new Error(), 'format.setext');
  } });
  const entries = lines.filter(line => line.text.trim() || lines.length === 1).map(line => {
    const start = prefix(line.text).content;
    const heading = /^(#{1,6})(?:[ \t]+|$)/.exec(line.text.slice(start));
    return { line, start, heading };
  });
  const remove = entries.every(entry => entry.heading?.[1].length === level);
  const changes: ChangeSpec[] = [];
  for (const { line, start, heading } of entries) {
    changes.push({ from: line.from + start, to: line.from + start + (heading?.[0].length ?? 0), insert: remove ? '' : '#'.repeat(level) + ' ' });
    const closing = remove ? /[ \t]+#+[ \t]*$/.exec(line.text.slice(start + (heading?.[0].length ?? 0))) : null;
    if (closing) changes.push({ from: line.from + start + (heading?.[0].length ?? 0) + closing.index, to: line.to, insert: '' });
  }
  return mapped(state, changes);
}
function lists(state: EditorState, command: BlockFormat): TransactionSpec {
  const lines = selectedLines(state), selectedNumbers = new Set(lines.map(line => line.number));
  selectionTree(state).iterate({ from: lines[0].from, to: lines.at(-1)!.to, enter(node) {
    if (node.name === 'ListItem' && selectedNumbers.has(state.doc.lineAt(node.from).number) && state.doc.lineAt(node.from).number !== state.doc.lineAt(node.to).number) {
      throw localizeError(new Error(), 'format.nestedList');
    }
  } });
  const entries = lines.filter(line => line.text.trim() || lines.length === 1).map(line => ({ line, ...prefix(line.text) }));
  const matches = (entry: typeof entries[number]) => command === 'task-list' ? !!entry.list?.[3] : command === 'ordered-list' ? !!entry.list?.[2] && !entry.list?.[3] : !!entry.list?.[1] && !entry.list?.[3];
  const remove = entries.every(matches);
  return mapped(state, entries.map((entry, index) => ({ from: entry.line.from + entry.start, to: entry.line.from + entry.content,
    insert: remove ? '' : command === 'task-list' ? '- ' + (entry.list?.[3] ?? '[ ] ') : command === 'ordered-list' ? `${index + 1}. ` : '- ' })));
}
function quote(state: EditorState): TransactionSpec {
  let lines = selectedLines(state), first = lines[0].from, last = lines.at(-1)!.to;
  // Markdown permits lazy continuation lines. Quote whole paragraphs so an
  // unmarked adjacent line is not accidentally absorbed into a new quote.
  selectionTree(state).iterate({ from: first, to: last, enter(node) {
    if (node.name === 'Paragraph') { first = Math.min(first, state.doc.lineAt(node.from).from); last = Math.max(last, state.doc.lineAt(node.to).to); }
  } });
  const firstNumber = state.doc.lineAt(first).number, lastNumber = state.doc.lineAt(last).number;
  if (lastNumber - firstNumber + 1 > 10000) throw localizeError(new Error(), 'format.quoteLimit', {limit: 10000});
  lines = Array.from({ length: lastNumber - firstNumber + 1 }, (_, index) => state.doc.line(firstNumber + index));
  selectionTree(state).iterate({ from: first, to: last, enter(node) {
    if (['ListItem', 'Blockquote'].includes(node.name) && (state.doc.lineAt(node.from).from < first || node.to > last)) throw localizeError(new Error(), 'format.completeBlock');
  } });
  const remove = lines.some(line => /^[ ]{0,3}>/.test(line.text))
    && lines.every(line => /^[ ]{0,3}>/.test(line.text) || !line.text.trim());
  return mapped(state, lines.map(line => {
    const mark = /^([ ]{0,3})>[ \t]?/.exec(line.text);
    return remove ? { from: line.from + (mark?.[1].length ?? 0), to: line.from + (mark?.[0].length ?? 0), insert: '' } : { from: line.from, insert: '> ' };
  }));
}
function fence(state: EditorState): TransactionSpec {
  const lines = selectedLines(state), node = enclosingNode(state, ['FencedCode']);
  if (node) {
    const first = node.firstChild!, last = node.lastChild!;
    if (first.from === last.from || first.name !== 'CodeMark' || last.name !== 'CodeMark') throw localizeError(new Error(), 'format.unclosedFence');
    const opening = state.doc.lineAt(first.from), closing = state.doc.lineAt(last.from);
    if (opening.from !== node.from || !/^(`{3,}|~{3,})/.test(opening.text)) throw localizeError(new Error(), 'format.nestedFence');
    return mapped(state, [{ from: opening.from, to: Math.min(opening.to + 1, closing.from) }, { from: Math.max(opening.to + 1, closing.from - 1), to: closing.to }]);
  }
  const first = lines[0], last = lines.at(-1)!;
  selectionTree(state).iterate({ from: first.from, to: last.to, enter(node) {
    if (['ListItem', 'Blockquote', 'FencedCode'].includes(node.name)) throw localizeError(new Error(), 'format.fenceContext');
  } });
  const text = state.doc.sliceString(first.from, last.to);
  let longest = 2;
  for (const match of text.matchAll(/`+/g)) longest = Math.max(longest, match[0].length);
  const marker = '`'.repeat(longest + 1);
  const changes = state.changes([{ from: first.from, insert: marker + '\n' }, { from: last.to, insert: '\n' + marker }]);
  const start = first.from + marker.length + 1;
  return { changes, selection: state.selection.main.empty ? EditorSelection.cursor(start + state.selection.main.head - first.from) : EditorSelection.single(start, start + text.length) };
}
export function blockFormat(state: EditorState, command: BlockFormat): TransactionSpec {
  guardTextBlocks(state, command === 'code-block');
  if (command === 'code-block') return fence(state);
  if (command === 'blockquote') return quote(state);
  if (command.startsWith('heading-')) return headings(state, Number(command.slice(-1)));
  return lists(state, command);
}
