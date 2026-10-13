import { Compartment } from '@codemirror/state';
import { EditorView, ViewPlugin, type ViewUpdate } from '@codemirror/view';
import { writingOptions } from './state.ts';

/** Reconfigure a real editor theme so font changes invalidate CodeMirror's
 * measured line heights even when the content's minimum height stays fixed. */
export function zoomLayout() {
  const layout = new Compartment();
  const theme = (zoom: number) => EditorView.theme({ '&': { '--ot-editor-scale': String(zoom) } });
  return [layout.of(theme(1)), ViewPlugin.fromClass(class {
    private applied = 1;
    private queued = false;
    private disposed = false;
    private readonly view: EditorView;
    constructor(view: EditorView) { this.view = view; }
    update(_update: ViewUpdate) {
      if (this.queued || this.disposed || this.applied === this.view.state.field(writingOptions).zoom) return;
      this.queued = true;
      queueMicrotask(() => {
        this.queued = false;
        if (this.disposed) return;
        const zoom = this.view.state.field(writingOptions).zoom;
        if (zoom === this.applied) return;
        this.applied = zoom;
        this.view.dispatch({ effects: layout.reconfigure(theme(zoom)) });
      });
    }
    destroy() { this.disposed = true; }
  })];
}
