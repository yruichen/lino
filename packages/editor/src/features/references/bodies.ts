import { EditorState, type Text } from '@codemirror/state';
import { parser, GFM } from '@lezer/markdown';
import type { Tree } from '@lezer/common';

export interface FootnoteBody { state: EditorState; tree: Tree; toSource(position: number): number }
const cache = new WeakMap<Text, WeakMap<Tree, readonly FootnoteBody[]>>();
/** Definition bodies remove their container prefix but retain an exact source map. */
export function footnoteBodies(state: EditorState, tree: Tree): readonly FootnoteBody[] {
  const found = cache.get(state.doc)?.get(tree); if (found) return found;
  const result: FootnoteBody[] = [], seen = new Set<string>();
  tree.iterate({ enter(node) {
    if (node.name !== 'FootnoteDefinition') return;
    const label = node.node.getChild('FootnoteLabel'); if (!label) return false;
    const id = state.sliceDoc(label.from + 2, label.to - 1);
    if (seen.has(id)) return false; seen.add(id);
    const first = state.doc.lineAt(label.to), offsets: number[] = [], lines: string[] = [];
    for (let number = first.number; number <= state.doc.lineAt(node.to).number; number++) {
      const line = state.doc.line(number), from = number === first.number ? label.to : line.from;
      const text = state.sliceDoc(from, Math.min(line.to, node.to));
      const prefix = number === first.number ? /^:[ \t]*/.exec(text)?.[0].length ?? 0 : /^(?: {4}|\t)/.exec(text)?.[0].length ?? 0;
      offsets.push(from + prefix); lines.push(text.slice(prefix));
    }
    const body = EditorState.create({ doc: lines.join('\n') });
    // Root-only metadata/math extensions are not applied inside definitions.
    result.push({ state: body, tree: parser.configure(GFM).parse(body.doc.toString()), toSource(position) {
      const line = body.doc.lineAt(position); return offsets[line.number - 1] + position - line.from;
    } });
    return false;
  } });
  let entries = cache.get(state.doc); if (!entries) { entries = new WeakMap(); cache.set(state.doc, entries); }
  entries.set(tree, result); return result;
}
