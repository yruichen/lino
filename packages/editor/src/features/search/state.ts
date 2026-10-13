import { Facet, StateField, type EditorState } from '@codemirror/state';
import { getSearchQuery, searchPanelOpen } from '@codemirror/search';
import type { SearchProjection } from '@lino/protocol/editor-host';

export const nativeSearchUI = Facet.define<boolean, boolean>({ combine: values => values[0] ?? false });
export const MATCH_LIMIT = 10000;
export interface SearchMatches { ranges: { from: number; to: number }[]; overflow: boolean }
export function computeMatches(state: EditorState): SearchMatches {
  const query = getSearchQuery(state), ranges: SearchMatches['ranges'] = [];
  if (!query.valid) return { ranges, overflow: false };
  const cursor = query.getCursor(state);
  for (let next = cursor.next(); !next.done; next = cursor.next()) {
    if (ranges.length === MATCH_LIMIT) return { ranges, overflow: true };
    ranges.push({ from: next.value.from, to: next.value.to });
  }
  return { ranges, overflow: false };
}
// This is a cached projection of CodeMirror's query and current document,
// not a writable second search state. Cursor/status updates reuse the ranges.
export const querySummary = StateField.define({
  create: state => ({ query: getSearchQuery(state), matches: computeMatches(state) }),
  update(value, tr) {
    const query = getSearchQuery(tr.state);
    return tr.docChanged || !query.eq(value.query) ? { query, matches: computeMatches(tr.state) } : value;
  },
});
export function searchMatches(state: EditorState): SearchMatches { return state.field(querySummary, false)?.matches ?? computeMatches(state); }
export function selectedSearchMatch(state: EditorState): { from: number; to: number } | undefined {
  if (!searchPanelOpen(state)) return;
  const selection = state.selection.main;
  return searchMatches(state).ranges.find(range => range.from === selection.from && range.to === selection.to);
}
export function searchProjection(state: EditorState, replacing: boolean, sequence: string): SearchProjection {
  const query = getSearchQuery(state), matches = searchMatches(state), selection = state.selection.main;
  return { open: searchPanelOpen(state), text: query.search, querySequence: sequence, count: matches.ranges.length, overflow: matches.overflow,
    index: matches.ranges.findIndex(range => range.from === selection.from && range.to === selection.to) + 1,
    error: !!query.search && !query.valid, replacing, caseSensitive: query.caseSensitive, wholeWord: query.wholeWord, regexp: query.regexp };
}
