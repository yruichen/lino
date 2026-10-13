import { StateEffect, StateField, Transaction } from '@codemirror/state';

export interface CodeViewOptions { numbers: boolean; wrap: boolean }
export const changeCodeOptions = StateEffect.define<Partial<CodeViewOptions>>();
// View options affect all code blocks in this editor. They are not document data
// or another persisted settings store, and never enter interaction history.
export const codeOptions = StateField.define<CodeViewOptions>({
  create: () => ({ numbers: false, wrap: true }),
  update: (value, transaction) => transaction.effects.reduce((result, effect) => effect.is(changeCodeOptions) ? { ...result, ...effect.value } : result, value),
});
export const codeViewTransaction = (options: Partial<CodeViewOptions>) => ({ effects: changeCodeOptions.of(options), annotations: Transaction.addToHistory.of(false) });
