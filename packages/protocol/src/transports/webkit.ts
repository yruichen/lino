import { TransportError } from '../client/documents.ts';
import type { EditorHostEvent } from '../client/editor-host.ts';
type HostWindow = Window & {
  __linoViewGeneration?: number;
  webkit?: { messageHandlers?: { editor?: { postMessage: (event: EditorHostEvent & { viewGeneration?: number }) => void } } };
};

// The only frontend module allowed to touch the platform message handler.
export function notifyHost(event: EditorHostEvent): void {
  const host = window as HostWindow;
  const handler = host.webkit?.messageHandlers?.editor;
  if (!handler && event.kind === "rpc") throw new TransportError("Open the editor in the Lino application.");
  handler?.postMessage({ ...event, viewGeneration: host.__linoViewGeneration });
}
export function hostGeneration(): number | undefined { return (window as HostWindow).__linoViewGeneration; }
