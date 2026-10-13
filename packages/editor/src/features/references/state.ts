import { StateEffect, StateField } from '@codemirror/state';
import type { DocumentLink } from './model.ts';

export interface LinkDraft { from: number; to: number; original: string; label: string; url: string; title: string; shared: boolean; valid: boolean; previous?: DocumentLink }
export const openReferenceDraft = StateEffect.define<LinkDraft>();
export const patchReferenceDraft = StateEffect.define<Partial<Pick<LinkDraft, 'label' | 'url' | 'title'>>>();
export const closeReferencePanel = StateEffect.define<null>();
export const referenceFeedback = StateEffect.define<{ error?: unknown; copied?: boolean }>();
export const referenceControls = StateField.define<{ draft?: LinkDraft; error?: unknown; copied?: boolean }>({
  create: () => ({}),
  update(value, tr) {
    if (value.draft && tr.docChanged) {
      const draft = value.draft; let valid = draft.valid;
      tr.changes.iterChangedRanges((from, to) => {
        if (draft.from === draft.to ? from <= draft.from && to > draft.from : from < draft.to && to > draft.from) valid = false;
      });
      value = { ...value, draft: { ...draft, valid, from: tr.changes.mapPos(draft.from, 1), to: tr.changes.mapPos(draft.to, draft.from === draft.to ? 1 : -1) } };
    }
    for (const effect of tr.effects) {
      if (effect.is(openReferenceDraft)) value = { draft: effect.value };
      if (effect.is(patchReferenceDraft) && value.draft) value = { draft: { ...value.draft, ...effect.value } };
      if (effect.is(referenceFeedback)) value = { ...value, ...effect.value };
      if (effect.is(closeReferencePanel)) value = {};
    }
    return value;
  },
});
