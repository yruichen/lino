// Native view commands and UI projections. Document DTOs are generated from Rust.
export const editorCommands = ['visual', 'source', 'toggle-source', 'undo', 'redo', 'insert-table', 'add-row', 'add-column', 'delete-row', 'delete-column', 'move-row-up', 'move-row-down', 'move-column-left', 'move-column-right', 'align-column-left', 'align-column-center', 'align-column-right', 'delete-table', 'find', 'replace', 'find-next', 'find-previous', 'goto-line', 'bold', 'italic', 'strikethrough', 'inline-code', 'link', 'heading-1', 'heading-2', 'heading-3', 'heading-4', 'heading-5', 'heading-6', 'bullet-list', 'ordered-list', 'task-list', 'blockquote', 'code-block'] as const;
export type EditorCommand = typeof editorCommands[number];
export interface EditorStatus {
  mode: 'visual' | 'source';
  composing: boolean;
  pendingMode: boolean;
  canUndo: boolean;
  canRedo: boolean;
  changedFromInitial: boolean;
}
export type EditorHostEvent =
  | { kind: 'ready' }
  | { kind: 'rpc'; json: string }
  | { kind: 'document'; dirty: boolean; saving: boolean; hasFile: boolean; label: string | null; revision: string;
      recoveryRevision: string | null; recoveryState: 'pending' | 'saving' | 'saved' | 'error';
      recoveryError: string | null; autosave: boolean; autosaveError: string | null }
  | { kind: 'status'; status: EditorStatus }
  | { kind: 'error'; message: string };
