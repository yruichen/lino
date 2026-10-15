export type RenderKind = 'math' | 'diagram';
export const MAX_PREVIEW_TEXT = 50_000;
export interface RenderInput { kind: RenderKind; text: string; block: boolean; dark: boolean }
export interface RenderResult { html: string; mathml?: string; svg?: string }
export class PreviewError extends Error {
  readonly reason: 'limit' | 'busy' | 'cancelled';
  constructor(reason: 'limit' | 'busy' | 'cancelled', message = reason) { super(message); this.reason = reason; }
}
type Work = { input: RenderInput; signal: AbortSignal; resolve(value: RenderResult): void; reject(error: unknown): void; abort(): void };
/** One renderer at a time protects Mermaid's global config and bounds work. */
export class PreviewRenderer {
  private running = false;
  private queue: Work[] = [];
  private cache = new Map<string, RenderResult>();
  private size = 0;
  private readonly render: (input: RenderInput) => Promise<RenderResult>;
  constructor(render: (input: RenderInput) => Promise<RenderResult> = renderPreview) { this.render = render; }
  /** Mounted previews can use cached markup before their first layout. */
  cached(input: RenderInput): RenderResult | undefined {
    const key = JSON.stringify(input), found = this.cache.get(key);
    if (found) { this.cache.delete(key); this.cache.set(key, found); }
    return found;
  }
  immediate(input: RenderInput): RenderResult | undefined {
    if (this.render !== renderPreview || input.kind !== 'math' || input.text.length > MAX_PREVIEW_TEXT) return undefined;
    const renderer = (window as Window & { LinoMath?: RendererModule }).LinoMath;
    const result = renderer?.renderSync?.(input);
    if (result) this.remember(JSON.stringify(input), result);
    return result;
  }
  private remember(key: string, result: RenderResult): void {
    const size = key.length + result.html.length + (result.mathml?.length ?? 0) + (result.svg?.length ?? 0);
    if (size > 4 * 1024 * 1024) throw new PreviewError('limit');
    if (this.cache.has(key)) return;
    this.cache.set(key, result); this.size += size;
    while (this.size > 4 * 1024 * 1024) {
      const [oldKey, old] = this.cache.entries().next().value!;
      this.cache.delete(oldKey); this.size -= oldKey.length + old.html.length + (old.mathml?.length ?? 0) + (old.svg?.length ?? 0);
    }
  }
  request(input: RenderInput, signal: AbortSignal): Promise<RenderResult> {
    if (signal.aborted) return Promise.reject(new PreviewError('cancelled'));
    if (input.text.length > MAX_PREVIEW_TEXT) return Promise.reject(new PreviewError('limit'));
    const found = this.cached(input);
    if (found) return Promise.resolve(found);
    if (this.queue.length >= 24) return Promise.reject(new PreviewError('busy'));
    return new Promise((resolve, reject) => {
      const work: Work = { input, signal, resolve, reject, abort: () => {
        this.queue = this.queue.filter(item => item !== work); reject(new PreviewError('cancelled'));
      } };
      signal.addEventListener('abort', work.abort, { once: true }); this.queue.push(work); void this.drain();
    });
  }
  private async drain(): Promise<void> {
    if (this.running) return; this.running = true;
    try {
      while (this.queue.length) {
        const work = this.queue.shift()!;
        try {
          if (work.signal.aborted) throw new PreviewError('cancelled');
          const key = JSON.stringify(work.input);
          const result = this.cache.get(key) ?? await this.render(work.input);
          if (work.signal.aborted) throw new PreviewError('cancelled');
          this.remember(key, result);
          work.resolve(result);
        } catch (error) { work.reject(error); }
        finally { work.signal.removeEventListener('abort', work.abort); }
      }
    } finally { this.running = false; }
  }
}
export async function renderPreview(input: RenderInput): Promise<RenderResult> {
  const renderer = await loadRenderer(input.kind); return renderer.render(input);
}
interface RendererModule { render(input: RenderInput): Promise<RenderResult>; renderSync?(input: RenderInput): RenderResult }
const modules = new Map<RenderKind, Promise<RendererModule>>();
function loadRenderer(kind: RenderKind): Promise<RendererModule> {
  const prepared = kind === 'math' ? (window as Window & { LinoMath?: RendererModule }).LinoMath : undefined;
  if (prepared?.renderSync) return Promise.resolve(prepared);
  const cached = modules.get(kind); if (cached) return cached;
  // Separate local classic-script bundles preserve the tested file:// host;
  // no ESM/file-origin migration or third-party CDN is needed for lazy loading.
  const promise = new Promise<RendererModule>((resolve, reject) => {
    const script = document.createElement('script'); script.src = `${kind}.js`;
    const style = kind === 'math' ? document.createElement('link') : undefined;
    let scriptReady = false, styleReady = !style;
    const fail = (reason: string) => { clearTimeout(timer); script.remove(); style?.remove(); reject(new Error(reason)); };
    const ready = () => {
      if (!scriptReady || !styleReady) return;
      clearTimeout(timer);
      const renderer = (window as Window & { LinoMath?: RendererModule; LinoDiagram?: RendererModule })[kind === 'math' ? 'LinoMath' : 'LinoDiagram'];
      if (renderer) resolve(renderer); else fail('Renderer module is missing');
    };
    const timer = setTimeout(() => fail('Renderer loading timed out'), 15_000);
    if (style) {
      style.rel = 'stylesheet'; style.href = 'math.css';
      style.addEventListener('load', () => { styleReady = true; ready(); }, { once: true });
      style.addEventListener('error', () => fail('Renderer styles could not load'), { once: true }); document.head.append(style);
    }
    script.addEventListener('load', () => { scriptReady = true; ready(); }, { once: true });
    script.addEventListener('error', () => fail('Renderer module could not load'), { once: true });
    document.head.append(script);
  });
  modules.set(kind, promise); void promise.catch(() => { if (modules.get(kind) === promise) modules.delete(kind); }); return promise;
}
export const previewRenderer = new PreviewRenderer();
