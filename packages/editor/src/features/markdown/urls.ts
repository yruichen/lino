import { decodeHTMLStrict } from 'entities';
import { syntaxTree } from '@codemirror/language';
import { footnoteBodies } from '../references/bodies.ts';
import type { EditorState } from '@codemirror/state';

export const markdownUnescape = (text: string): string => decodeHTMLStrict(text.replace(/\\([!"#$%&'()*+,\-./:;<=>?@[\]\\^_`{|}~])/g, '$1'));
export const markdownDestination = (text: string): string => markdownUnescape(text.startsWith('<') ? text.slice(1, -1) : text);
export const referenceKey = (text: string): string => markdownUnescape(text).trim().replace(/\s+/g, ' ').toLowerCase();
export interface LinkDefinition { from: number; to: number; url: string; title?: string; titleSource?: string }
export function linkDefinitions(state: EditorState, tree = syntaxTree(state), bodies = footnoteBodies(state, tree)): Map<string, LinkDefinition> {
  const result = new Map<string, LinkDefinition>();
  tree.iterate({ enter(node) {
    if (node.name !== 'LinkReference') return;
    const label = node.node.getChild('LinkLabel'), url = node.node.getChild('URL'), title = node.node.getChild('LinkTitle');
    if (label && url) {
      const key = referenceKey(state.sliceDoc(label.from + 1, label.to - 1));
      const titleSource = title ? state.sliceDoc(title.from + 1, title.to - 1) : undefined;
      if (!result.has(key)) result.set(key, { from: node.from, to: node.to, url: markdownDestination(state.sliceDoc(url.from, url.to)), title: titleSource === undefined ? undefined : markdownUnescape(titleSource), titleSource });
    }
    return false;
  } });
  for (const body of bodies) {
    for (const [key, value] of linkDefinitions(body.state, body.tree, [])) {
      const definition = { ...value, from: body.toSource(value.from), to: body.toSource(value.to) };
      if (!result.has(key) || result.get(key)!.from > definition.from) result.set(key, definition);
    }
  }
  return result;
}
export function escapedLabel(text: string): string { return text.replace(/[\\[\]]/g, '\\$&').replace(/&/g, '&amp;'); }
export function escapedDestination(text: string): string { return text.replace(/[\s<>"\\]/g, char => encodeURIComponent(char)).replace(/&/g, '&amp;'); }
export function escapedTitle(text: string): string { return text.replace(/[\\"]/g, '\\$&').replace(/&/g, '&amp;'); }
