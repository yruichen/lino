import { StateEffect, StateField, type EditorState } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import type { AssetPort } from '@lino/protocol/assets';
import type { WriteClipboard } from '../code/controls.ts';
export interface MediaHost { assets: AssetPort; copy: WriteClipboard }
const hosts = new WeakMap<EditorView, MediaHost>();
export const mediaContextChanged = StateEffect.define<null>();
export function setMediaHost(view: EditorView, host: MediaHost): void {
  const replacing = hosts.has(view); hosts.set(view, host);
  // Initial widgets start after mount and can read the newly registered port.
  // Only replacement needs invalidation; construction must not emit an extra
  // document callback while the previous session is still being detached.
  if (replacing) view.dispatch({ effects: mediaContextChanged.of(null) });
}
export function mediaHost(view: EditorView): MediaHost | undefined { return hosts.get(view); }
export const imageScale = StateEffect.define<{ from: number; to: number; scale: number }>();
export const imageSizes = StateField.define<ReadonlyMap<number, { to: number; scale: number }>>({
  create: () => new Map(),
  update(value, tr) {
    if (!tr.docChanged && !tr.effects.some(effect => effect.is(imageScale))) return value;
    const next = new Map<number, { to: number; scale: number }>();
    for (const [from, entry] of value) {
      let touched = false;
      tr.changes.iterChangedRanges((a, b) => { if (a < entry.to && b > from || a === b && a > from && a < entry.to) touched = true; });
      if (!touched) next.set(tr.changes.mapPos(from, 1), { ...entry, to: tr.changes.mapPos(entry.to, -1) });
    }
    for (const effect of tr.effects) if (effect.is(imageScale)) {
      const { from, to, scale } = effect.value;
      if (scale === 1) next.delete(from); else next.set(from, { to, scale: Math.min(2, Math.max(.25, scale)) });
    }
    return next;
  },
});
export const startImport = StateEffect.define<{ id: number; from: number; to: number }>();
export const finishImport = StateEffect.define<number>();
export const importAnchor = StateField.define<{ id: number; from: number; to: number; valid: boolean } | null>({
  create: () => null,
  update(value, tr) {
    if (value && tr.docChanged) {
      const old = value; let valid = old.valid;
      tr.changes.iterChangedRanges((from, to) => {
        if (old.from === old.to ? from <= old.from && to > old.from : from < old.to && to > old.from) valid = false;
      });
      value = { ...old, from: tr.changes.mapPos(old.from, 1), to: tr.changes.mapPos(old.to, old.from === old.to ? 1 : -1), valid };
    }
    for (const effect of tr.effects) {
      if (effect.is(mediaContextChanged) && value) value = { ...value, valid: false };
      if (effect.is(startImport)) value = { ...effect.value, valid: true };
      if (effect.is(finishImport) && value?.id === effect.value) value = null;
    }
    return value;
  },
});
export function writable(state: EditorState, composing: boolean): boolean { return !state.readOnly && !composing; }
