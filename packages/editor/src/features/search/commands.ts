import { EditorState, StateEffect, StateField, type Extension } from '@codemirror/state';
import { isolateHistory } from '@codemirror/commands';
import { closeSearchPanel, findNext, findPrevious, getSearchQuery, openSearchPanel, replaceAll, replaceNext, searchPanelOpen, setSearchQuery } from '@codemirror/search';
import type { EditorView } from '@codemirror/view';
import { compositionState } from '../source-mode/state.ts';

export type SearchCommand = 'find' | 'replace' | 'find-next' | 'find-previous';
export const showReplacement = StateEffect.define<boolean>();
export const replacementVisible = StateField.define({
  create: () => false,
  update: (value, transaction) => transaction.effects.reduce((current, effect) => effect.is(showReplacement) ? effect.value : current, value),
});

// Bound the simultaneous change array and count projection. Navigation remains
// available beyond this limit; no matches or document content are truncated.
export const MATCH_LIMIT = 10000;
export interface SearchMatches { ranges: { from: number; to: number }[]; overflow: boolean }
export function searchMatches(state: EditorState): SearchMatches {
  const query = getSearchQuery(state), ranges: SearchMatches['ranges'] = [];
  if (!query.valid) return { ranges, overflow: false };
  const cursor = query.getCursor(state);
  for (let next = cursor.next(); !next.done; next = cursor.next()) {
    if (ranges.length === MATCH_LIMIT) return { ranges, overflow: true };
    ranges.push({ from: next.value.from, to: next.value.to });
  }
  return { ranges, overflow: false };
}
export function canReplace(state: EditorState, composing = false): boolean {
  return !state.readOnly && !composing && !state.field(compositionState, false);
}
export const replacementTransactions: Extension = [
  EditorState.transactionFilter.of(transaction => transaction.docChanged && transaction.isUserEvent('input.replace') && !canReplace(transaction.startState) ? [] : transaction),
  EditorState.transactionExtender.of(transaction => transaction.docChanged && transaction.isUserEvent('input.replace') ? { annotations: isolateHistory.of('full') } : null),
];
export function replaceMatches(view: EditorView, all: boolean): boolean {
  if (!canReplace(view.state, view.composing) || !getSearchQuery(view.state).valid) return false;
  if (all && searchMatches(view.state).overflow) return false;
  return (all ? replaceAll : replaceNext)(view);
}
export function runSearchCommand(view: EditorView, command: SearchCommand): boolean {
  if (view.composing || view.state.field(compositionState, false)) return false;
  if (command === 'find' || command === 'replace') {
    openSearchPanel(view);
    view.dispatch({ effects: showReplacement.of(command === 'replace') });
    return true;
  }
  if (!searchPanelOpen(view.state)) {
    const query = getSearchQuery(view.state);
    openSearchPanel(view);
    if (query.valid) view.dispatch({ effects: setSearchQuery.of(query) });
  }
  return (command === 'find-next' ? findNext : findPrevious)(view);
}
export { closeSearchPanel };
