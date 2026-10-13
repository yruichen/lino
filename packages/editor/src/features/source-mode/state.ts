import { StateEffect, StateField } from '@codemirror/state';

export type EditorMode = 'visual' | 'source';
export const changeMode = StateEffect.define<EditorMode>();
export const changeComposition = StateEffect.define<boolean>();
export const modeState = StateField.define<EditorMode>({
  create: () => 'visual',
  update: (mode, transaction) => transaction.effects.reduce((value, effect) => effect.is(changeMode) ? effect.value : value, mode),
});
export const compositionState = StateField.define<boolean>({
  create: () => false,
  update: (composing, transaction) => transaction.effects.reduce((value, effect) => effect.is(changeComposition) ? effect.value : value, composing),
});
