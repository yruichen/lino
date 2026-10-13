import { EditorState, StateEffect, StateField, type Extension } from '@codemirror/state';
import { isolateHistory } from '@codemirror/commands';
import { closeSearchPanel, findNext, findPrevious, getSearchQuery, openSearchPanel, replaceAll, replaceNext, searchPanelOpen, setSearchQuery } from '@codemirror/search';
import type { EditorView } from '@codemirror/view';
import { compositionState } from '../source-mode/state.ts';

import { MATCH_LIMIT, searchMatches } from './state.ts';
export { MATCH_LIMIT, searchMatches, type SearchMatches } from './state.ts';
export type SearchCommand = 'find' | 'replace' | 'find-next' | 'find-previous' | 'toggle-find' | 'close-find';
export const showReplacement = StateEffect.define<boolean>();
export const replacementVisible = StateField.define({
  create: () => false,
  update: (value, transaction) => transaction.effects.reduce((current, effect) => effect.is(showReplacement) ? effect.value : current, value),
});

// Bound the simultaneous change array and count projection. Navigation remains
// available beyond this limit; no matches or document content are truncated.
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
  if (command === 'close-find' || command === 'toggle-find' && searchPanelOpen(view.state)) return closeSearchPanel(view);
  if (command === 'toggle-find') command = 'find';
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
