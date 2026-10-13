import { StateField } from '@codemirror/state';
import { syntaxTree } from '@codemirror/language';
import { Decoration, EditorView, WidgetType, type DecorationSet } from '@codemirror/view';
import { AssetLocationError } from '@lino/protocol/assets';
import { localeFacet } from '../../localization/editor.ts';
import { tFor, type Locale, type MessageKey } from '../../localization/index.ts';
import { previewRenderer, PreviewError, MAX_PREVIEW_TEXT, type RenderResult } from '../../renderers/previews.ts';
import { compositionState, modeState } from '../source-mode/state.ts';
import { imageScale, imageSizes, mediaContextChanged, mediaHost } from './state.ts';
import { previewSources, type PreviewSource } from './model.ts';
import { componentMenu } from '../../controls/components.ts';
import { presentationSelection, presentationSelectionChanged } from '../../controls/pointer.ts';

const bindings = new WeakMap<HTMLElement, { view: EditorView; abort: AbortController; refresh(): void; cancel(): void; result?: RenderResult }>();
const nodes = new WeakMap<EditorView, Set<HTMLElement>>();
type LabelKey = Exclude<Extract<MessageKey, `media.${string}`>, 'media.failed' | 'media.orphan'>;
export function selectedPreview(view: EditorView, command: 'refresh' | 'cancel'): boolean {
  const position = view.state.selection.main.head;
  for (const node of nodes.get(view) ?? []) {
    if (Number(node.dataset.previewFrom) <= position && Number(node.dataset.previewTo) >= position) {
      bindings.get(node)?.[command](); return true;
    }
  }
  return false;
}
export function currentPreviewResult(view: EditorView, from: number): RenderResult | undefined {
  for (const node of nodes.get(view) ?? []) if (Number(node.dataset.previewFrom) === from) return bindings.get(node)?.result;
  return undefined;
}
class PreviewWidget extends WidgetType {
  readonly source: PreviewSource; readonly raw: string; readonly dark: boolean; readonly locale: Locale; readonly context: number; readonly scale: number;
  constructor(source: PreviewSource, raw: string, dark: boolean, locale: Locale, context: number, scale: number) { super(); this.source = source; this.raw = raw; this.dark = dark; this.locale = locale; this.context = context; this.scale = scale; }
  override eq(other: PreviewWidget): boolean { return this.source.from === other.source.from && this.source.to === other.source.to && this.raw === other.raw && this.dark === other.dark && this.locale === other.locale && this.context === other.context && this.scale === other.scale; }
  toDOM(view: EditorView): HTMLElement {
    const source = this.source, root: HTMLElement = document.createElement(source.block ? 'div' : 'span');
    root.className = `ot-preview ot-preview-${source.kind}${source.block ? ' ot-preview-block' : ' ot-preview-inline'}`; root.dataset.previewFrom = String(source.from); root.dataset.previewTo = String(source.to);
    root.setAttribute('aria-label', tFor(this.locale, `media.${source.kind}`));
    root.tabIndex = 0;
    const content = root.appendChild(document.createElement('span')); content.className = 'ot-preview-content';
    const status = root.appendChild(document.createElement('output')); status.setAttribute('role', 'status');
    const say = (key: LabelKey) => tFor(this.locale, key);
    const alive = () => root.isConnected && view.dom.isConnected && view.state.sliceDoc(source.from, Math.min(source.to, source.from + MAX_PREVIEW_TEXT + 2)) === this.raw;
    const report = (error: unknown) => {
      if (!alive()) return;
      status.textContent = error instanceof AssetLocationError ? say('media.needsLocation')
        : error instanceof PreviewError ? tFor(this.locale, `media.${error.reason}`)
        : tFor(this.locale, 'media.failed', { reason: error instanceof Error ? error.message : String(error) });
    };
    const edit = () => {
      if (!alive() || view.composing || view.state.field(compositionState)) return;
      // Edit the actual source body in the existing text/history owner.
      const position = source.kind === 'image' ? source.from + 2
        : source.kind === 'math' ? source.from + (source.block ? 3 : 1)
        : Math.min(source.to, view.state.doc.lineAt(source.from).to + 1);
      const scroll = view.scrollSnapshot();
      view.dispatch({ selection: { anchor: Math.min(source.to, position) }, effects: scroll }); view.focus();
    };
    // Prevent a focusable preview's native mousedown from scrolling/focusing it
    // before the click handler edits the source and restores the viewport.
    root.addEventListener('mousedown', event => { if (event.button === 0 && !(event.target as Element).closest('button')) event.preventDefault(); });
    root.addEventListener('click', event => {
      if ((event.target as Element).closest('button')) return;
      event.preventDefault(); edit();
    });
    root.addEventListener('keydown', event => { if (event.key === 'Enter' && !event.isComposing) { event.preventDefault(); edit(); } });
    root.addEventListener('contextmenu', event => { edit(); componentMenu(view, source.kind, event); });
    const binding = { view, abort: new AbortController(), refresh: () => {}, cancel: () => {}, result: undefined as RenderResult | undefined };
    const render = (fresh = false) => {
      binding.abort.abort(); binding.abort = new AbortController(); binding.result = undefined; status.textContent = say('media.loading'); content.replaceChildren();
      if (source.kind === 'image') {
        const controller = binding.abort;
        const image = document.createElement('img'); image.alt = source.alt ?? ''; image.title = source.title ?? ''; image.loading = 'lazy'; image.decoding = 'async';
        image.addEventListener('load', () => {
          if (!alive() || controller.signal.aborted) return;
          if (image.naturalWidth * image.naturalHeight > 64_000_000) { image.removeAttribute('src'); report(new PreviewError('limit')); return; }
          if (this.scale !== 1 && image.naturalWidth) image.style.width = `${image.naturalWidth * this.scale}px`;
          status.textContent = ''; view.requestMeasure();
        });
        image.addEventListener('error', () => { if (!controller.signal.aborted) report(new Error(`${say('media.imageFailed')} ${source.text}`)); });
        const start = () => {
          if (controller.signal.aborted) return;
          if (/^https?:\/\//i.test(source.text)) image.src = source.text;
          else if (/^[a-z][a-z\d+.-]*:/i.test(source.text) || source.text.startsWith('//')) { report(new Error(say('media.protocol'))); return; }
          else {
            const host = mediaHost(view); if (!host) { report(new Error(say('media.noHost'))); return; }
            try { image.src = host.assets.imageURL(source.text, fresh); } catch (error) { report(error); return; }
          }
          content.replaceChildren(image);
          controller.signal.addEventListener('abort', () => { image.removeAttribute('src'); }, { once: true });
        };
        if (/^https?:\/\//i.test(source.text)) {
          status.textContent = say('media.remote');
          const load = content.appendChild(document.createElement('button')); load.type = 'button'; load.textContent = say('media.loadRemote'); load.addEventListener('click', start);
        } else start();
        return;
      }
      const controller = binding.abort;
      if (source.tooLarge) { report(new PreviewError('limit')); return; }
      void previewRenderer.request({ kind: source.kind, text: source.text, block: source.block, dark: this.dark }, controller.signal).then(result => {
        if (!alive() || controller.signal.aborted) return;
        binding.result = result; content.innerHTML = result.html; status.textContent = ''; view.requestMeasure();
      }, error => { if (!controller.signal.aborted) report(error); });
    };
    binding.refresh = () => render(true);
    binding.cancel = () => { binding.abort.abort(); content.replaceChildren(); binding.result = undefined; status.textContent = say('media.cancelled'); };
    bindings.set(root, binding); const set = nodes.get(view) ?? new Set<HTMLElement>(); set.add(root); nodes.set(view, set);
    if (source.kind === 'image') {
      root.dataset.imageScale = String(this.scale);
    }
    // toDOM runs before insertion. Start in a microtask so async callbacks can
    // verify the mounted widget; no timer controls document state.
    queueMicrotask(() => { if (alive()) render(); }); return root;
  }
  override destroy(dom: HTMLElement): void { const binding = bindings.get(dom); binding?.abort.abort(); if (binding) nodes.get(binding.view)?.delete(dom); bindings.delete(dom); }
  override ignoreEvent(): boolean { return true; }
}
interface Previews { decorations: DecorationSet; context: number; sources: readonly PreviewSource[] }
function build(state: import('@codemirror/state').EditorState, context: number, sources: readonly PreviewSource[] = previewSources(state)): Previews {
  if (state.field(modeState) === 'source' || state.field(compositionState)) return { decorations: Decoration.none, context, sources };
  const ranges: ReturnType<Decoration['range']>[] = [];
  for (const source of sources) {
    const active = presentationSelection(state).ranges.some(range => range.from <= source.to && range.to >= source.from);
    const widget = new PreviewWidget(source, state.sliceDoc(source.from, Math.min(source.to, source.from + MAX_PREVIEW_TEXT + 2)), state.facet(EditorView.darkTheme), state.facet(localeFacet), context, state.field(imageSizes, false)?.get(source.from)?.scale ?? 1);
    if (active) ranges.push(Decoration.widget({ widget, block: source.block, side: 1 }).range(source.to));
    else ranges.push(Decoration.replace({ widget, block: source.block }).range(source.from, source.to));
  }
  return { decorations: Decoration.set(ranges, true), context, sources };
}
export const mediaPresentation = StateField.define<Previews>({
  create: state => build(state, 0),
  update(value, tr) {
    const context = value.context + (tr.effects.some(effect => effect.is(mediaContextChanged)) ? 1 : 0);
    const syntaxChanged = tr.docChanged || syntaxTree(tr.startState) !== syntaxTree(tr.state);
    if (tr.docChanged || presentationSelectionChanged(tr.startState, tr.state) || tr.effects.some(effect => effect.is(imageScale)) || context !== value.context || tr.startState.field(modeState) !== tr.state.field(modeState)
      || tr.startState.field(compositionState) !== tr.state.field(compositionState) || tr.startState.facet(localeFacet) !== tr.state.facet(localeFacet)
      || tr.startState.facet(EditorView.darkTheme) !== tr.state.facet(EditorView.darkTheme)
      || syntaxChanged) return build(tr.state, context, syntaxChanged ? previewSources(tr.state) : value.sources);
    return value;
  }, provide: field => EditorView.decorations.from(field, value => value.decorations),
});
