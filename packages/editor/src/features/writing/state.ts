import { StateEffect, StateField } from '@codemirror/state';
import { nativeAnalysisUI } from '../analysis/capabilities.ts';
import { EditorView } from '@codemirror/view';
export interface WritingOptions { outline: boolean; statistics: boolean; focus: boolean; typewriter: boolean; zoom: number }
export const changeWriting = StateEffect.define<Partial<WritingOptions>>();
export const writingOptions = StateField.define<WritingOptions>({
  create: () => ({ outline: false, statistics: true, focus: false, typewriter: false, zoom: 1 }),
  update: (value, tr) => tr.effects.reduce((next, effect) => effect.is(changeWriting) ? { ...next, ...effect.value } : next, value),
  provide: field => EditorView.editorAttributes.compute([field, nativeAnalysisUI], state => ({
    class: state.field(field).outline && !state.facet(nativeAnalysisUI) ? 'ot-outline-open' : '',
    'data-typewriter': String(state.field(field).typewriter),
  })),
});
export function writingCommand(view: EditorView, command: string): boolean {
  const current = view.state.field(writingOptions);
  const keys = { 'toggle-outline': 'outline', 'toggle-statistics': 'statistics', 'focus-mode': 'focus', 'typewriter-mode': 'typewriter' } as const;
  const key = keys[command as keyof typeof keys];
  const zoom = command === 'zoom-in' ? Math.min(2, Math.round((current.zoom + 0.1) * 10) / 10)
    : command === 'zoom-out' ? Math.max(0.7, Math.round((current.zoom - 0.1) * 10) / 10) : command === 'zoom-reset' ? 1 : undefined;
  if (!key && zoom === undefined) return false;
  view.dispatch({ effects: changeWriting.of(key ? { [key]: !current[key] } : { zoom }) });
  return true;
}
