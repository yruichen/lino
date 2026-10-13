import { type EditorView, type Panel } from '@codemirror/view';
import { contextualControls, focusContext } from '../../controls/contextual.ts';
import type { ReferenceCommand } from '@lino/protocol/editor-host';
import { localeFacet } from '../../localization/editor.ts';
import { t, tFor } from '../../localization/index.ts';
import { formatError } from '../../localization/errors.ts';
import { compositionState } from '../source-mode/state.ts';
import { mediaHost } from '../media/state.ts';
import { escapedDestination, escapedTitle } from '../markdown/urls.ts';
import { enclosingNode, guardTextBlocks } from '../markdown/selection.ts';
import { linkAt } from './model.ts';
import { openLink, navigateFootnote, referenceEdit, referenceInsertion, serializedLink, unlink } from './commands.ts';
import { referenceControls, openReferenceDraft, patchReferenceDraft, closeReferencePanel, referenceFeedback } from './state.ts';

export const referencePanels = contextualControls('reference', referenceControls, (state, value) => value.draft?.from ?? (value.error || value.copied ? state.selection.main.head : null), createReferencePanel);

export function referenceReport(view: EditorView, error: unknown): void {
  if (view.dom.isConnected) view.dispatch({ effects: [focusContext.of('reference'), referenceFeedback.of({ error, copied: false })] });
}
export function runReferenceCommand(view: EditorView, command: ReferenceCommand | 'link'): boolean {
  if (view.composing || view.state.field(compositionState, false)) return false;
  try {
    if (command === 'open-link' || command === 'copy-link') {
      const link = linkAt(view.state); if (!link) throw new Error(t('references.selectLink'));
      if (command === 'open-link') return openLink(view, link.url, error => referenceReport(view, error));
      const host = mediaHost(view); if (!host) throw new Error(t('media.noHost'));
      const doc = view.state.doc;
      void host.copy(link.url).then(() => {
        if (view.dom.isConnected && view.state.doc === doc) view.dispatch({ effects: [focusContext.of('reference'), referenceFeedback.of({ copied: true, error: undefined })] });
      }, error => { if (view.state.doc === doc) referenceReport(view, error); });
      return true;
    }
    if (command === 'goto-footnote') return navigateFootnote(view);
    if (view.state.readOnly) return false;
    if (command === 'unlink') return unlink(view);
    if (command === 'link' || command === 'link-properties' || command === 'edit-link-reference') {
      guardTextBlocks(view.state);
      if (enclosingNode(view.state, ['InlineCode', 'InlineMath', 'Image'])) throw new Error(t('format.textOnly'));
      const previous = linkAt(view.state), shared = command === 'edit-link-reference';
      if (shared && !previous?.definition) throw new Error(t('references.noDefinition'));
      const range = shared ? previous!.definition! : previous ?? view.state.selection.main;
      const from = range.from, to = range.to;
      view.dispatch({ effects: [focusContext.of('reference'), openReferenceDraft.of({ from, to, original: view.state.sliceDoc(from, to), shared, valid: true, previous,
        label: previous?.label ?? view.state.sliceDoc(from, to), url: previous?.url ?? '', title: previous?.title ?? '' })] });
      queueMicrotask(() => { if (view.dom.isConnected) view.dom.querySelector<HTMLInputElement>('input[name=link-url]')?.focus(); });
      return true;
    }
    return referenceInsertion(view, command);
  } catch (error) { referenceReport(view, error); return false; }
}
export function createReferencePanel(view: EditorView): Panel {
  const dom = document.createElement('form'); dom.className = 'ot-reference-tools';
  const caption = dom.appendChild(document.createElement('strong'));
  const fields = (['label', 'url', 'title'] as const).map(name => {
    const label = dom.appendChild(document.createElement('label'));
    const text = label.appendChild(document.createElement('span'));
    const input = label.appendChild(document.createElement('input')); input.name = `link-${name}`; input.type = 'text';
    input.addEventListener('input', () => { if (!composing) view.dispatch({ effects: patchReferenceDraft.of({ [name]: input.value }) }); });
    return { name, label, text, input };
  });
  const apply = dom.appendChild(document.createElement('button')); apply.type = 'submit';
  const close = dom.appendChild(document.createElement('button')); close.type = 'button';
  const note = dom.appendChild(document.createElement('p'));
  const feedback = dom.appendChild(document.createElement('output')); feedback.setAttribute('role', 'status');
  let composing = false;
  const frozen = () => composing || view.composing || !!view.state.field(compositionState, false);
  const update = () => {
    const state = view.state.field(referenceControls), draft = state.draft, locale = view.state.facet(localeFacet);
    caption.textContent = tFor(locale, draft?.shared ? 'references.definition' : 'references.properties');
    for (const field of fields) {
      field.label.hidden = !draft || draft.shared && field.name === 'label';
      field.text.textContent = tFor(locale, `references.${field.name}`);
      field.input.setAttribute('aria-label', field.text.textContent);
      if (draft && !composing && field.input.value !== draft[field.name]) field.input.value = draft[field.name];
    }
    apply.hidden = !draft; apply.textContent = tFor(locale, 'media.apply');
    apply.disabled = !draft?.valid || !draft.url.trim() || view.state.readOnly || frozen();
    close.textContent = tFor(locale, 'media.close');
    note.textContent = draft?.shared ? tFor(locale, 'references.shared') : draft?.previous?.definition ? tFor(locale, 'references.inlineOccurrence') : '';
    feedback.textContent = draft && !draft.valid ? tFor(locale, 'references.changed') : state.error ? formatError(state.error) : state.copied ? tFor(locale, 'media.copied') : '';
  };
  const dismiss = () => { if (!frozen()) { view.dispatch({ effects: [focusContext.of(null), closeReferencePanel.of(null)] }); view.focus(); } };
  close.addEventListener('click', dismiss);
  dom.addEventListener('keydown', event => { if (event.key === 'Escape' && !event.isComposing && !frozen()) { event.preventDefault(); dismiss(); } });
  dom.addEventListener('compositionstart', () => { composing = true; update(); });
  dom.addEventListener('compositionend', () => { composing = false; view.dispatch({ effects: fields.map(({ name, input }) => patchReferenceDraft.of({ [name]: input.value })) }); update(); });
  dom.addEventListener('submit', event => {
    event.preventDefault(); if (frozen() || view.state.readOnly) return;
    const draft = view.state.field(referenceControls).draft;
    if (!draft?.valid || view.state.sliceDoc(draft.from, draft.to) !== draft.original) { referenceReport(view, new Error(t('references.changed'))); return; }
    try {
      const inline = serializedLink(draft.label, draft.url, draft.title, draft.previous);
      const colon = draft.original.indexOf(']:');
      const insert = draft.shared ? `${draft.original.slice(0, colon + 2)} <${escapedDestination(draft.url.trim())}>${draft.title ? ` "${escapedTitle(draft.title)}"` : ''}` : inline;
      view.dispatch({ ...referenceEdit(view.state, draft.from, draft.to, insert), effects: closeReferencePanel.of(null) }); view.focus();
    } catch (error) { referenceReport(view, error); }
  });
  update(); return { dom, update };
}
