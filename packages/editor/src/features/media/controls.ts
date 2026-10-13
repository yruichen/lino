import { StateEffect, StateField } from '@codemirror/state';
import { EditorView, type Panel, type ViewUpdate } from '@codemirror/view';
import { contextualControls, focusContext } from '../../controls/contextual.ts';
import type { MediaCommand } from '@lino/protocol/editor-host';
import { tFor, type MessageKey } from '../../localization/index.ts';
import { localeFacet } from '../../localization/editor.ts';
import { changeComposition, compositionState } from '../source-mode/state.ts';
import { applyImage, importImage, insertSpecial } from './commands.ts';
import { guardTextBlocks } from '../markdown/selection.ts';
import { previewAt } from './model.ts';
import { imageScale, imageSizes, mediaHost } from './state.ts';
import { currentPreviewResult, selectedPreview } from './view.ts';

interface Draft { from: number; to: number; original: string; source: string; alt: string; title: string; stale: boolean; reference: boolean }
const openDraft = StateEffect.define<Draft | null>();
const editDraft = StateEffect.define<Partial<Pick<Draft, 'source' | 'alt' | 'title'>>>();
const feedback = StateEffect.define<string>();
interface Controls { draft: Draft | null; message: string }
export const mediaControls = StateField.define<Controls>({
  create: () => ({ draft: null, message: '' }),
  update(value, tr) {
    let draft = value.draft, message = value.message;
    if (draft && tr.docChanged) {
      let touched = false;
      tr.changes.iterChangedRanges((from, to) => { if (draft!.from === draft!.to ? from <= draft!.from && to > draft!.from : from < draft!.to && to > draft!.from) touched = true; });
      draft = { ...draft, from: tr.changes.mapPos(draft.from, 1), to: tr.changes.mapPos(draft.to, draft.from === draft.to ? 1 : -1), stale: draft.stale || touched };
    }
    for (const effect of tr.effects) {
      if (effect.is(openDraft)) { draft = effect.value; message = ''; }
      if (effect.is(editDraft) && draft) draft = { ...draft, ...effect.value };
      if (effect.is(feedback)) message = effect.value;
    }
    return { draft, message };
  }, provide: field => contextualControls('media', field, (state, value) => value.draft?.from ?? (value.message ? state.selection.main.head : null), mediaPanel),
});
function mediaPanel(view: EditorView): Panel { return new MediaPanel(view); }
function report(view: EditorView, error: unknown): void {
  if (view.dom.isConnected) view.dispatch({ effects: [focusContext.of('media'), feedback.of(error instanceof Error ? error.message : String(error))] });
}
export function runMediaCommand(view: EditorView, command: MediaCommand): boolean {
  if (view.composing || view.state.field(compositionState)) return false;
  const locale = view.state.facet(localeFacet);
  try {
    if (command === 'image-properties') {
      const image = previewAt(view.state), range = image?.kind === 'image' ? image : view.state.selection.main;
      if (image?.kind !== 'image') guardTextBlocks(view.state);
      view.dispatch({ effects: [focusContext.of('media'), openDraft.of({ from: range.from, to: range.to, original: view.state.sliceDoc(range.from, range.to),
        source: image?.kind === 'image' ? image.text : '', alt: image?.kind === 'image' ? image.alt ?? '' : view.state.sliceDoc(range.from, range.to), title: image?.kind === 'image' ? image.title ?? '' : '', reference: image?.reference ?? false, stale: false })] });
      queueMicrotask(() => { if (!view.dom.querySelector('.ot-media-panel input:focus')) view.dom.querySelector<HTMLInputElement>('input[name=image-source]')?.focus(); }); return true;
    }
    if (command === 'image-import' || command === 'image-paste') {
      void importImage(view, command === 'image-paste').catch(error => report(view, error)); return true;
    }
    if (['image-smaller', 'image-larger', 'image-reset-size', 'image-reveal', 'image-copy'].includes(command)) {
      const image = previewAt(view.state);
      if (image?.kind !== 'image') throw new Error(tFor(locale, 'media.selectPreview'));
      if (command === 'image-smaller' || command === 'image-larger' || command === 'image-reset-size') {
        const scale = view.state.field(imageSizes).get(image.from)?.scale ?? 1;
        view.dispatch({ effects: imageScale.of({ from: image.from, to: image.to, scale: command === 'image-reset-size' ? 1 : command === 'image-smaller' ? scale / 1.25 : scale * 1.25 }) });
      } else {
        const host = mediaHost(view); if (!host) throw new Error(tFor(locale, 'media.noHost'));
        void host.assets.request(command === 'image-reveal' ? 'reveal-image' : 'copy-image', image.text).catch(error => report(view, error));
      }
      return true;
    }
    if (command === 'math-inline' || command === 'math-block' || command === 'insert-diagram') return insertSpecial(view, command);
    if (command === 'preview-refresh' || command === 'preview-cancel') {
      if (!selectedPreview(view, command === 'preview-refresh' ? 'refresh' : 'cancel')) throw new Error(tFor(locale, 'media.selectPreview'));
      return true;
    }
    const selected = previewAt(view.state), host = mediaHost(view);
    if (!selected || selected.kind === 'image') throw new Error(tFor(locale, 'media.selectPreview'));
    if (selected.tooLarge) throw new Error(tFor(locale, 'media.limit'));
    if (!host) throw new Error(tFor(locale, 'media.noHost'));
    const result = currentPreviewResult(view, selected.from);
    const value = command === 'preview-copy-source' ? selected.text : command === 'preview-copy-mathml' ? result?.mathml : result?.svg;
    if (!value) throw new Error(tFor(locale, 'media.notReady'));
    const doc = view.state.doc;
    const operation = command === 'preview-save-svg' ? host.assets.request('save-svg', value) : host.copy(value);
    void operation.then(value => { if (view.dom.isConnected && view.state.doc === doc && (command !== 'preview-save-svg' || value !== null)) view.dispatch({ effects: [focusContext.of('media'), feedback.of(tFor(locale, command === 'preview-save-svg' ? 'media.saved' : 'media.copied'))] }); }, error => { if (view.state.doc === doc) report(view, error); });
    return true;
  } catch (error) { report(view, error); return false; }
}
class MediaPanel implements Panel {
  readonly dom = document.createElement('form');
  private readonly fields = new Map<'source' | 'alt' | 'title', HTMLInputElement>();
  private readonly labels = new Map<string, Text>();
  private readonly apply = document.createElement('button');
  private readonly close = document.createElement('button');
  private readonly status = document.createElement('output');
  private readonly reference = document.createElement('span');
  private readonly view: EditorView;
  constructor(view: EditorView) {
    this.view = view;
    this.dom.className = 'ot-media-panel';
    for (const key of ['source', 'alt', 'title'] as const) {
      const label = this.dom.appendChild(document.createElement('label')), text = document.createTextNode(''); label.append(text); this.labels.set(key, text);
      const input = label.appendChild(document.createElement('input')); input.name = `image-${key}`; this.fields.set(key, input);
      input.addEventListener('input', () => view.dispatch({ effects: editDraft.of({ [key]: input.value }) }));
      input.addEventListener('compositionstart', () => view.dispatch({ effects: changeComposition.of(true) }));
      input.addEventListener('compositionend', () => view.dispatch({ effects: [editDraft.of({ [key]: input.value }), changeComposition.of(false)] }));
    }
    this.apply.type = 'submit'; this.apply.name = 'image-apply'; this.close.type = 'button'; this.close.name = 'image-close'; this.status.setAttribute('role', 'status');
    this.dom.append(this.apply, this.close, this.reference, this.status);
    this.close.addEventListener('click', () => { if (view.state.field(compositionState)) return; view.dispatch({ effects: [focusContext.of(null), openDraft.of(null)] }); view.focus(); });
    this.dom.addEventListener('keydown', event => { if (event.key === 'Escape' && !event.isComposing) { event.preventDefault(); this.close.click(); } });
    this.dom.addEventListener('submit', event => {
      event.preventDefault(); const draft = view.state.field(mediaControls).draft; if (!draft) return;
      try {
        if (draft.stale) throw new Error(tFor(view.state.facet(localeFacet), 'media.changed'));
        if (applyImage(view, draft.from, draft.to, draft.original, draft.source, draft.alt, draft.title)) view.dispatch({ effects: openDraft.of(null) });
      } catch (error) { report(view, error); }
    }); this.refresh();
  }
  update(_update: ViewUpdate): void { this.refresh(); }
  private refresh(): void {
    const { draft, message } = this.view.state.field(mediaControls), locale = this.view.state.facet(localeFacet);
    for (const [key, field] of this.fields) {
      field.parentElement!.hidden = !draft; this.labels.get(key)!.textContent = tFor(locale, `media.${key}`);
      if (draft && field.value !== draft[key]) field.value = draft[key];
      field.disabled = this.view.state.readOnly;
    }
    this.apply.hidden = !draft; this.apply.disabled = this.view.state.readOnly || !!draft?.stale;
    this.apply.textContent = tFor(locale, 'media.apply'); this.close.textContent = tFor(locale, 'media.close');
    this.reference.textContent = draft?.reference ? tFor(locale, 'media.reference') : '';
    this.status.textContent = message || (draft?.stale ? tFor(locale, 'media.changed') : '');
    this.dom.setAttribute('aria-label', tFor(locale, 'media.properties'));
  }
}
