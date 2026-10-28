// Native view commands and UI projections. Document DTOs are generated from Rust.
import shortcuts from '../generated/shortcuts.json' with { type: 'json' };
export const markdownShortcuts = shortcuts;
export const codeCommands = ['code-language', 'code-indent', 'code-outdent', 'code-copy', 'code-line-numbers', 'code-wrap'] as const;
export type CodeCommand = typeof codeCommands[number];
export const mediaCommands = ['image-properties', 'image-import', 'image-paste', 'image-smaller', 'image-larger', 'image-reset-size', 'image-reveal', 'image-copy', 'math-inline', 'math-block', 'insert-diagram', 'preview-copy-source', 'preview-copy-mathml', 'preview-copy-svg', 'preview-save-svg', 'preview-refresh', 'preview-cancel'] as const;
export type MediaCommand = typeof mediaCommands[number];
export const referenceCommands = ['link-properties', 'open-link', 'copy-link', 'unlink', 'edit-link-reference', 'insert-footnote', 'goto-footnote', 'insert-toc', 'insert-frontmatter', 'horizontal-rule'] as const;
export type ReferenceCommand = typeof referenceCommands[number];
export const structureCommands = ['paragraph', 'highlight', 'superscript', 'subscript', 'clear-formatting', 'indent', 'outdent', 'toggle-task'] as const;
export const editorCommands = ['toggle-find', 'close-find', 'visual', 'source', 'toggle-source', 'undo', 'redo', 'insert-table', 'add-row', 'add-column', 'delete-row', 'delete-column', 'move-row-up', 'move-row-down', 'move-column-left', 'move-column-right', 'align-column-left', 'align-column-center', 'align-column-right', 'delete-table', 'find', 'replace', 'find-next', 'find-previous', 'goto-line', 'bold', 'italic', 'strikethrough', 'inline-code', 'link', 'heading-1', 'heading-2', 'heading-3', 'heading-4', 'heading-5', 'heading-6', 'bullet-list', 'ordered-list', 'task-list', 'blockquote', 'code-block', ...codeCommands, ...mediaCommands, ...referenceCommands, ...structureCommands, 'toggle-outline', 'toggle-statistics', 'focus-mode', 'typewriter-mode', 'zoom-in', 'zoom-out', 'zoom-reset'] as const;
export type EditorCommand = typeof editorCommands[number];
export interface SearchProjection { open: boolean; text: string; querySequence: string; count: number; index: number; overflow: boolean; error: boolean; replacing: boolean; caseSensitive: boolean; wholeWord: boolean; regexp: boolean }
export type ComponentContext = 'image' | 'math' | 'diagram' | 'table' | 'code';
export interface EditorStatus {
  mode: 'visual' | 'source';
  composing: boolean;
  pendingMode: boolean;
  canUndo: boolean;
  canRedo: boolean;
  changedFromInitial: boolean;
  codeBlock: boolean;
  codeFenced: boolean;
  codeCanIndent: boolean;
  codeWrap: boolean;
  codeNumbers: boolean;
  outline: boolean;
  statistics: boolean;
  focus: boolean;
  typewriter: boolean;
  zoom: number;
  cursorLine: number;
  cursorColumn: number;
  selectionLength: number;
  search: SearchProjection;
}
export type EditorHostEvent =
  | { kind: 'context-menu'; context: ComponentContext; x: number; y: number; imageScale?: number }
  | { kind: 'ready' }
  | { kind: 'image-drop'; names: string[]; x: number; y: number }
  | { kind: 'outline'; token: string; entries?: { id: string; from: number; to: number; level: number; title: string }[]; current: number | null; complete: boolean; truncated: boolean; exhausted: boolean }
  | { kind: 'statistics'; counts: { words: number; characters: number; nonWhitespace: number; lines: number }; selection: boolean; visible: boolean }
  | { kind: 'rpc'; json: string }
  | { kind: 'document'; dirty: boolean; saving: boolean; hasFile: boolean; label: string | null; revision: string;
      readOnly?: boolean; documentKind?: string; sessionId?: string; epoch?: string; fileRef?: string | null;
      recoveryRevision: string | null; recoveryState: 'pending' | 'saving' | 'saved' | 'error';
      recoveryError: string | null; autosave: boolean; autosaveError: string | null }
  | { kind: 'status'; status: EditorStatus }
  | { kind: 'clipboard-write'; requestId: string; text: string }
  | { kind: 'asset-operation'; requestId: string; operation: import('./assets.ts').AssetOperation; payload: string; sessionId: string | null; fileRef: string | null }
  | { kind: 'error'; message: string };
