import { Transaction, type EditorState, type TransactionSpec } from '@codemirror/state';
import { getIndentUnit, indentString } from '@codemirror/language';
import { isolateHistory } from '@codemirror/commands';
import { compositionState } from '../source-mode/state.ts';
import { codeBlockAt, codeLineStart, selectedCodeLines, CodeError } from './model.ts';

function writable(state: EditorState): boolean { return !state.readOnly && !state.field(compositionState, false); }
function editing(state: EditorState, changes: TransactionSpec['changes']): TransactionSpec {
  const set = state.changes(changes!);
  return { changes: set, selection: state.selection.map(set, 1), scrollIntoView: true,
    annotations: [Transaction.userEvent.of('input.code'), isolateHistory.of('full')] };
}
export function codeLanguageTransaction(state: EditorState, language: string): TransactionSpec | undefined {
  if (!writable(state)) return undefined;
  const block = codeBlockAt(state);
  if (!block) throw new CodeError('selectBlock');
  if (!block.fenced) throw new CodeError('indentedLanguage');
  // Preserve the rest of the info string; a picker must not discard attributes.
  language = language.trim();
  if (language && !/^[\p{L}\p{N}_+.#-]{1,80}$/u.test(language)) throw new CodeError('language');
  // Leaving only an attribute suffix would promote it to a language token.
  // An explicit plain-text tag preserves that suffix without changing its role.
  const opening = state.doc.lineAt(block.from);
  if (!language && state.doc.sliceString(block.languageTo, opening.to).trim()) language = 'text';
  if (block.language === language) return undefined;
  return editing(state, { from: block.languageFrom, to: block.languageTo, insert: language });
}
export function codeIndentTransaction(state: EditorState, direction: 1 | -1): TransactionSpec | undefined {
  if (!writable(state)) return undefined;
  const block = codeBlockAt(state);
  if (!block) throw new CodeError('selectBlock');
  const selected = selectedCodeLines(state, block);
  if (!selected) throw new CodeError('selection');
  const { first, last } = selected;
  if (last - first >= 10000) throw new CodeError('limit');
  const unit = getIndentUnit(state), insert = indentString(state, unit);
  const changes = [];
  for (let number = first; number <= last; number++) {
    const line = state.doc.line(number), from = codeLineStart(block, line);
    if (direction === 1) changes.push({ from, insert });
    else {
      const prefix = /^[ \t]*/.exec(state.doc.sliceString(from, line.to))![0];
      const length = prefix.startsWith('\t') ? 1 : Math.min(unit, prefix.length);
      if (length) changes.push({ from, to: from + length });
    }
  }
  return changes.length ? editing(state, changes) : undefined;
}
