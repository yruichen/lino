import { isolateHistory } from '@codemirror/commands';
import { EditorSelection, type TransactionSpec } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import { compositionState } from '../source-mode/state.ts';
import { codeBlockAt } from '../code/model.ts';
import { guardTextBlocks } from '../markdown/selection.ts';
import { imageMarkdown, importedSource, previewAt } from './model.ts';
import { finishImport, importAnchor, mediaHost, startImport, writable } from './state.ts';
import { t } from '../../localization/index.ts';
let sequence = 0;
const imports = new WeakMap<EditorView, Promise<string | null>>();
export async function settleImports(view: EditorView): Promise<void> { await imports.get(view); }
export function replaceSource(from: number, to: number, insert: string): TransactionSpec {
  return { changes: { from, to, insert }, selection: EditorSelection.cursor(from + insert.length), annotations: isolateHistory.of('full'), userEvent: 'input.media' };
}
export function insertSpecial(view: EditorView, kind: 'math-inline' | 'math-block' | 'insert-diagram'): boolean {
  if (!writable(view.state, view.composing || !!view.state.field(compositionState, false))) return false;
  let selected = view.state.selection.main, source = view.state.sliceDoc(selected.from, selected.to);
  if (codeBlockAt(view.state)) throw new Error(t('media.sourceOnly'));
  const existing = previewAt(view.state);
  if (existing?.kind === 'math' && kind !== 'insert-diagram') {
    if (existing.tooLarge) throw new Error(t('media.limit'));
    if (existing.block === (kind === 'math-block')) { view.dispatch(replaceSource(existing.from, existing.to, existing.text)); view.focus(); return true; }
    selected = EditorSelection.range(existing.from, existing.to); source = existing.text;
  } else guardTextBlocks(view.state);
  let insert: string, offset: number;
  if (kind === 'math-inline') {
    if (/[\n$]/.test(source)) throw new Error(t('media.inlineSelection'));
    insert = `$${source || 'x'}$`; offset = 1;
  } else {
    const before = selected.from > 0 && view.state.sliceDoc(selected.from - 1, selected.from) !== '\n' ? '\n' : '';
    const after = selected.to < view.state.doc.length && view.state.sliceDoc(selected.to, selected.to + 1) !== '\n' ? '\n' : '';
    if (kind === 'math-block') {
      if (/^\s*\$\$/m.test(source)) throw new Error(t('media.delimiter'));
      insert = `${before}$$\n${source || 'x = y'}\n$$${after}`; offset = before.length + 3;
    } else {
      let fence = '```'; while (source.includes(fence)) fence += '`';
      insert = `${before}${fence}mermaid\n${source || 'flowchart LR\n  A --> B'}\n${fence}${after}`; offset = before.length + fence.length + 8;
    }
  }
  view.dispatch({ ...replaceSource(selected.from, selected.to, insert), selection: { anchor: selected.from + offset } }); view.focus(); return true;
}
export function importImage(view: EditorView, paste: boolean): Promise<string | null> {
  if (imports.has(view)) return Promise.reject(new Error(t('media.busy')));
  const work = performImport(view, paste); imports.set(view, work);
  void work.finally(() => { if (imports.get(view) === work) imports.delete(view); }).catch(() => {});
  return work;
}
async function performImport(view: EditorView, paste: boolean, sourcePath?: string, prepared = false): Promise<string | null> {
  const host = mediaHost(view);
  if (!host) throw new Error(t('media.noHost'));
  if (!writable(view.state, view.composing || !!view.state.field(compositionState, false))) throw new Error(t('editor.finishComposition'));
  if (!prepared && view.state.field(importAnchor)) throw new Error(t('media.busy'));
  if (!prepared) guardTextBlocks(view.state);
  const range = view.state.selection.main, id = prepared ? view.state.field(importAnchor)!.id : ++sequence;
  if (!prepared) view.dispatch({ effects: startImport.of({ id, from: range.from, to: range.to }) });
  try {
    const path = await host.assets.request(sourcePath ? 'import-image-path' : paste ? 'paste-image' : 'import-file', sourcePath);
    if (!path) return null;
    const anchor = view.state.field(importAnchor);
    if (!view.dom.isConnected || anchor?.id !== id || !anchor.valid || !writable(view.state, view.composing || !!view.state.field(compositionState, false))) throw new Error(t('media.orphan', { path }));
    view.dispatch(replaceSource(anchor.from, anchor.to, imageMarkdown(importedSource(path), ''))); view.focus(); return path;
  } finally {
    if (view.dom.isConnected && view.state.field(importAnchor)?.id === id) view.dispatch({ effects: finishImport.of(id) });
  }
}
export function applyImage(view: EditorView, from: number, to: number, original: string, source: string, alt: string, title: string): boolean {
  if (!writable(view.state, view.composing || !!view.state.field(compositionState, false))) return false;
  const current = previewAt(view.state, from);
  if (view.state.sliceDoc(from, to) !== original) throw new Error(t('media.changed'));
  if (current?.kind === 'image' && (current.from !== from || view.state.sliceDoc(current.from, current.to) !== original)) throw new Error(t('media.changed'));
  const range = current?.kind === 'image' ? current : { from, to };
  if (current?.kind === 'image' && current.text === source && current.alt === alt && (current.title ?? '') === title) { view.focus(); return true; }
  const insert = imageMarkdown(source, alt, title);
  view.dispatch(replaceSource(range.from, range.to, insert)); view.focus(); return true;
}

// Capture the drop position before native save panels run. The existing import
// anchor maps through edits; preparation never changes selection or history.
export function prepareImageDrop(view: EditorView, x: number, y: number): boolean {
  if (imports.has(view) || view.state.field(importAnchor) || !writable(view.state, view.composing || !!view.state.field(compositionState, false))) return false;
  const position = view.posAtCoords({ x, y }); if (position === null) return false;
  guardTextBlocks(view.state.update({ selection: { anchor: position } }).state);
  view.dispatch({ effects: startImport.of({ id: ++sequence, from: position, to: position, waitingForLocation: true }) });
  return true;
}
export function cancelImageDrop(view: EditorView): void {
  const anchor = view.state.field(importAnchor);
  if (anchor) view.dispatch({ effects: finishImport.of(anchor.id) });
}
export async function commitImageDrop(view: EditorView, paths: readonly string[]): Promise<void> {
  if (!paths.length || !view.state.field(importAnchor)?.valid || imports.has(view)) throw new Error(t('media.changed'));
  const anchor = view.state.field(importAnchor)!;
  view.dispatch({ effects: startImport.of({ id: anchor.id, from: anchor.from, to: anchor.to }) });
  const work = (async () => {
    let last: string | null = null;
    try {
      for (const path of paths) {
        last = await performImport(view, false, path, true);
        const at = view.state.selection.main.head;
        view.dispatch({ effects: startImport.of({ id: ++sequence, from: at, to: at }) });
      }
      return last;
    } finally { cancelImageDrop(view); }
  })();
  imports.set(view, work);
  try { await work; } finally { if (imports.get(view) === work) imports.delete(view); }
}
