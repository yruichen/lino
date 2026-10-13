import { localizeError, t } from '../../localization/index.ts';
import { EditorSelection, type ChangeSpec, type EditorState, type TransactionSpec } from '@codemirror/state';
import { markdownLanguage } from '@codemirror/lang-markdown';
import { language } from '@codemirror/language';
import { enclosingNode, guardTextBlocks, selectedLines, selectionTree, type MarkdownNode } from './selection.ts';

export type InlineFormat = 'bold' | 'italic' | 'strikethrough' | 'inline-code' | 'link' | 'highlight' | 'superscript' | 'subscript';
export const inlineNodeNames = { bold: 'StrongEmphasis', italic: 'Emphasis', strikethrough: 'Strikethrough', 'inline-code': 'InlineCode', highlight: 'Highlight', superscript: 'Superscript', subscript: 'Subscript' };
const nodeNames = inlineNodeNames;
function marks(text: string, command: Exclude<InlineFormat, 'link'>): string[] {
  if (command === 'bold') return ['**', '__'];
  if (command === 'italic') return ['*', '_'];
  if (command === 'strikethrough') return ['~~'];
  if (command === 'highlight') return ['=='];
  if (command === 'superscript') return ['^'];
  if (command === 'subscript') return ['~'];
  let longest = 0;
  for (const match of text.matchAll(/`+/g)) longest = Math.max(longest, match[0].length);
  return ['`'.repeat(longest + 1)];
}
function unwrap(state: EditorState, command: Exclude<InlineFormat, 'link'>): TransactionSpec | undefined {
  const node = enclosingNode(state, [nodeNames[command]]), range = state.selection.main;
  if (!node) return undefined;
  const opening = node.firstChild!, closing = node.lastChild!;
  if (!range.empty && !(range.from === node.from && range.to === node.to) && !(range.from === opening.to && range.to === closing.from)) {
    throw localizeError(new Error(), 'format.unwrap');
  }
  let from = opening.to, to = closing.from;
  if (command === 'inline-code') {
    const body = state.doc.sliceString(from, to);
    if (body.startsWith(' ') && body.endsWith(' ') && /[^ ]/.test(body)) { from++; to--; }
  }
  const changes = state.changes([{ from: node.from, to: from }, { from: to, to: node.to }]);
  return { changes, selection: range.empty ? state.selection.map(changes) : EditorSelection.single(changes.mapPos(from, -1), changes.mapPos(to, 1)) };
}
function link(state: EditorState): TransactionSpec {
  const range = state.selection.main;
  if (selectedLines(state).length > 1) throw localizeError(new Error(), 'format.linkLine');
  const current = enclosingNode(state, ['Link', 'Image']);
  if (current) {
    const url = current.getChild('URL');
    if (!url) throw localizeError(new Error(), 'format.referenceLink');
    return { selection: EditorSelection.single(url.from, url.to) };
  }
  const text = range.empty ? t('format.placeholderLink') : state.doc.sliceString(range.from, range.to);
  const label = text.replace(/[\\[\]]/g, '\\$&');
  const destination = 'https://example.com';
  const insert = `[${label}](${destination})`;
  const line = state.doc.lineAt(range.from), offset = range.from - line.from;
  const candidate = line.text.slice(0, offset) + insert + line.text.slice(range.to - line.from);
  let valid = false;
  markdownLanguage.parser.parse(candidate).iterate({ enter(node) {
    if (node.name === 'Link' && node.from === offset && node.to === offset + insert.length) valid = true;
  } });
  if (!valid) throw localizeError(new Error(), 'format.linkBoundary');
  return { changes: { from: range.from, to: range.to, insert }, selection: range.empty ?
    EditorSelection.single(range.from + 1, range.from + 1 + label.length) :
    EditorSelection.single(range.from + label.length + 3, range.from + label.length + 3 + destination.length) };
}
export function inlineFormat(state: EditorState, command: InlineFormat): TransactionSpec {
  guardTextBlocks(state);
  const selected = state.selection.main;
  selectionTree(state).iterate({ from: selected.from, to: selected.to, enter(node) {
    if (node.name === 'InlineMath' && (selected.from > node.from && selected.from < node.to || selected.to > node.from && selected.to < node.to)) throw localizeError(new Error(), 'format.textOnly');
  } });
  if (command === 'link') return link(state);
  const existing = unwrap(state, command);
  if (existing) return existing;
  const range = state.selection.main, lines = selectedLines(state);
  if (command === 'inline-code' && lines.length > 1) throw localizeError(new Error(), 'format.codeLine');
  const changes: ChangeSpec[] = [];
  const formatted = new Map<number, MarkdownNode>();
  if (lines.length > 1) {
    const tree = selectionTree(state);
    const spans = lines.map(line => {
      const start = Math.max(line.from, range.from), end = Math.min(line.to, range.to), text = state.doc.sliceString(start, end);
      return { from: start + text.length - text.trimStart().length, to: end - text.length + text.trimEnd().length };
    }).filter(span => span.from < span.to);
    for (const span of spans) tree.iterate({ from: span.from, to: span.to, enter(node) {
      if (node.name === nodeNames[command] && ((node.from === span.from && node.to === span.to) || (node.node.firstChild?.to === span.from && node.node.lastChild?.from === span.to))) formatted.set(span.from, node.node);
    } });
    if (spans.length && spans.every(span => formatted.has(span.from))) {
      const removals = state.changes(spans.flatMap(span => {
        const node = formatted.get(span.from)!;
        return [{ from: node.from, to: node.firstChild!.to }, { from: node.lastChild!.from, to: node.to }];
      }));
      return { changes: removals, selection: state.selection.map(removals) };
    }
  }
  let placeholder: { from: number; length: number } | undefined;
  for (const line of lines) {
    let from = Math.max(line.from, range.from), to = Math.min(line.to, range.to);
    let text = range.empty ? (command === 'inline-code' ? t('format.placeholderCode') : t('format.placeholderText')) : state.doc.sliceString(from, to);
    if (!range.empty && command !== 'inline-code') {
      from += text.length - text.trimStart().length;
      to -= text.length - text.trimEnd().length;
      text = state.doc.sliceString(from, Math.max(from, to));
    }
    if (!text || formatted.has(from)) continue;
    const padding = command === 'inline-code' && (/^`|`$/.test(text) || /^ .* $/.test(text) && /[^ ]/.test(text)) ? ' ' : '';
    let chosen: string | undefined;
    for (const mark of marks(text, command)) {
      const insert = mark + padding + text + padding + mark;
      const candidate = line.text.slice(0, from - line.from) + insert + line.text.slice(to - line.from);
      const offset = from - line.from;
      (state.facet(language) ?? markdownLanguage).parser.parse(candidate).iterate({ enter(node) {
        if (node.name === nodeNames[command] && node.from === offset && node.to === offset + insert.length) chosen = mark;
      } });
      if (chosen) break;
    }
    if (!chosen) throw localizeError(new Error(), 'format.boundary');
    changes.push({ from, to, insert: chosen + padding + text + padding + chosen });
    if (range.empty) placeholder = { from: from + chosen.length + padding.length, length: text.length };
  }
  const changeSet = state.changes(changes);
  return { changes: changeSet, selection: placeholder ? EditorSelection.single(placeholder.from, placeholder.from + placeholder.length) : state.selection.map(changeSet) };
}
