import { StateField, type Text } from '@codemirror/state';
import { syntaxTree, syntaxTreeAvailable } from '@codemirror/language';
import type { EditorState } from '@codemirror/state';

export interface Heading { from: number; to: number; level: number; title: string }
const titleMarks = new Set(['EmphasisMark', 'StrikethroughMark', 'CodeMark', 'HighlightMark', 'ScriptMark']);
export function headings(state: EditorState): { complete: boolean; entries: Heading[] } {
  const entries: Heading[] = [];
  const tree = syntaxTree(state);
  tree.iterate({ enter(node) {
    const match = /^(?:ATX|Setext)Heading([1-6])$/.exec(node.name);
    if (!match) return;
    let from = node.from, to = node.to;
    for (let child = node.node.firstChild; child; child = child.nextSibling) {
      if (child.name !== 'HeaderMark') continue;
      if (child.from === from) from = child.to;
      else to = child.from;
    }
    // Labels are a reading projection, while jump coordinates stay in source.
    // Only remove parsed delimiters: literal stars inside code or incomplete
    // Markdown must survive, unlike a blanket replacement of punctuation.
    let title = '', offset = from;
    node.node.cursor().iterate(child => {
      if (child.from < from || child.to > to) return;
      const replacement = titleMarks.has(child.name) ? ''
        : child.name === 'Escape' ? state.doc.sliceString(child.from + 1, child.to) : undefined;
      if (replacement === undefined) return;
      title += state.doc.sliceString(offset, child.from) + replacement;
      offset = child.to;
      return false;
    });
    title += state.doc.sliceString(offset, to);
    entries.push({ from: node.from, to: node.to, level: Number(match[1]), title: title.trim() });
    return false;
  } });
  // ensureSyntaxTree can advance the parser context before a transaction has
  // published that tree in this immutable state. Completeness must describe
  // the tree actually used above, not only the context's pending result.
  return { complete: tree.length >= state.doc.length && syntaxTreeAvailable(state, state.doc.length), entries };
}
export interface Counts { words: number; characters: number; nonWhitespace: number; lines: number }
const segmenter = new Intl.Segmenter('en', { granularity: 'word' });
// Each Han ideograph is one word; other scripts use Unicode word segmentation.
// Counts include Markdown source and code. Characters count Unicode code points.
export function countText(text: string): Counts {
  let words = 0, characters = 0, nonWhitespace = 0;
  for (const char of text) { characters++; if (!/\s/u.test(char)) nonWhitespace++; }
  for (const part of segmenter.segment(text)) {
    if (!part.isWordLike) continue;
    const han = [...part.segment].filter(char => /\p{Script=Han}/u.test(char)).length;
    words += han || 1;
  }
  return { words, characters, nonWhitespace, lines: text.split('\n').length };
}
// CodeMirror's immutable text tree shares unaffected children. Cache aggregate
// counts by actual tree identity; edits only recount changed leaves/ancestors.
// Weak keys release counts with the document/history rather than a global index.
const countsCache = new WeakMap<Text, Counts>();
export function countDocument(doc: Text): Counts {
  const cached = countsCache.get(doc);
  if (cached) return cached;
  let counts: Counts;
  if (!doc.children) counts = countText(doc.toString());
  else {
    counts = { words: 0, characters: doc.children.length - 1, nonWhitespace: 0, lines: 0 };
    for (const child of doc.children) {
      const value = countDocument(child);
      counts.words += value.words; counts.characters += value.characters;
      counts.nonWhitespace += value.nonWhitespace; counts.lines += value.lines;
    }
  }
  countsCache.set(doc, counts); return counts;
}
export const statistics = StateField.define<{ total: Counts }>({
  create: state => ({ total: countDocument(state.doc) }),
  update: (value, tr) => tr.docChanged ? { total: countDocument(tr.newDoc) } : value,
});
export function selectionCounts(state: EditorState): Counts | undefined {
  const ranges = state.selection.ranges.filter(range => !range.empty);
  if (!ranges.length) return;
  const counts: Counts = { words: 0, characters: ranges.length - 1, nonWhitespace: 0, lines: 0 };
  for (const range of ranges) {
    const value = countDocument(state.doc.slice(range.from, range.to));
    counts.words += value.words; counts.characters += value.characters;
    counts.nonWhitespace += value.nonWhitespace; counts.lines += value.lines;
  }
  return counts;
}
