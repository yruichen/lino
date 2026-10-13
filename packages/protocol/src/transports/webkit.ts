import type { EditorHostEvent } from '../client/editor-host.ts';

// The only frontend module allowed to touch the platform message handler.
export function notifyHost(event: EditorHostEvent): void {
  const host = window as Window & {
    __openTyporaViewGeneration?: number;
    webkit?: { messageHandlers?: { editor?: { postMessage: (event: EditorHostEvent & { viewGeneration?: number }) => void } } };
  };
  const handler = host.webkit?.messageHandlers?.editor;
  if (!handler && event.kind === "rpc") throw new Error("请在原生应用中打开编辑器。");
  handler?.postMessage({ ...event, viewGeneration: host.__openTyporaViewGeneration });
}
