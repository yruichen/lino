import { isolateHistory } from '@codemirror/commands';
import { Transaction, type EditorState, type TransactionSpec } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import { compositionState } from '../source-mode/state.ts';
import { blockFormat, type BlockFormat } from './blocks.ts';
import { inlineFormat, type InlineFormat } from './inline.ts';
import { selectionTree } from './selection.ts';

export const formatCommands = ['bold', 'italic', 'strikethrough', 'inline-code', 'link', 'heading-1', 'heading-2', 'heading-3', 'heading-4', 'heading-5', 'heading-6', 'bullet-list', 'ordered-list', 'task-list', 'blockquote', 'code-block'] as const;
export type FormatCommand = InlineFormat | BlockFormat;
export function formattingTransaction(state: EditorState, command: FormatCommand): TransactionSpec | undefined {
  if (state.readOnly || state.field(compositionState, false)) return undefined;
  selectionTree(state);
  const transaction = ['bold', 'italic', 'strikethrough', 'inline-code', 'link'].includes(command) ? inlineFormat(state, command as InlineFormat) : blockFormat(state, command as BlockFormat);
  return { ...transaction, scrollIntoView: true, annotations: [Transaction.userEvent.of('input.format'), isolateHistory.of('full')] };
}
export function applyFormat(view: EditorView, command: FormatCommand): boolean {
  if (view.composing) return false;
  const transaction = formattingTransaction(view.state, command);
  if (!transaction) return false;
  view.dispatch(transaction);
  return true;
}
