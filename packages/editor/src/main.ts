import { editorCommands, type EditorCommand } from '@open-typora/protocol/editor-host';
import { notifyHost } from '@open-typora/protocol/webkit';
import { DocumentClient } from '@open-typora/protocol/documents';
import type { OpenedDocument } from '@open-typora/protocol/generated/OpenedDocument';
import type { SaveTarget } from '@open-typora/protocol/generated/SaveTarget';
import { PROTOCOL_VERSION, RESOURCE_VERSION } from '@open-typora/protocol/generated/version';
import { MarkdownEditor } from './engine/editor.ts';
import { DocumentSession } from './session/document.ts';
import { verifyDocumentEdit, verifyEditor } from './verification.ts';
import { verifySearch } from './features/search/verification.ts';
import { verifyMarkdown } from './features/markdown/verification.ts';
import { verifyNavigation } from './features/navigation/verification.ts';
import { verifyTheme } from './themes/verification.ts';
import { verifyTableInsertion } from './features/tables/verification.ts';
import { currentLocale, setLocale, t } from './localization/index.ts';
import { formatError } from './localization/errors.ts';
import './styles/editor.css';

setLocale(currentLocale());
const root = document.getElementById('editor')!;
const report = (message: string) => notifyHost({ kind: 'error', message });
const client = new DocumentClient(json => notifyHost({ kind: 'rpc', json }));
let session: DocumentSession | undefined;
let autosave = false;
let editor = new MarkdownEditor(root, '', notifyHost, changed => session?.changed(changed));
editor.setReadOnly(true);
function publish(): void {
  if (session) notifyHost({ kind: 'document', dirty: session.dirty, saving: session.isSaving,
    hasFile: session.status.file_ref !== null, label: session.status.label, revision: session.status.revision,
    ...session.persistence.status });
}
function current(): DocumentSession { if (!session) throw new Error(t('document.notLoaded')); return session; }
const api = {
  command(command: EditorCommand) {
    if (!editorCommands.includes(command)) throw new Error(t('editor.unknownCommand'));
    return editor.command(command);
  },
  receive: (json: string) => client.receive(json),
  setLocale(value: unknown): void { setLocale(value); publish(); },
  transportError: (id: string, message: string) => client.fail(id, message),
  attachDocument(json: string): void {
    const opened: OpenedDocument = JSON.parse(json);
    if (opened.protocol_version !== PROTOCOL_VERSION || opened.resource_version !== RESOURCE_VERSION) throw new Error(t('document.protocolMismatch'));
    const holder = document.createElement('div');
    const next = new MarkdownEditor(holder, opened.text, notifyHost, changed => session?.changed(changed));
    session?.destroy(); editor.destroy(); root.replaceChildren(...Array.from(holder.childNodes)); editor = next;
    session = new DocumentSession(client, opened, editor, publish, report);
    session.persistence.setAutosave(autosave); publish();
  },
  async saveDocument(targetJson: string | null = null): Promise<void> {
    await editor.settleComposition();
    const target: SaveTarget | null = targetJson === null ? null : JSON.parse(targetJson);
    await current().save(target);
  },
  setAutosave(enabled: boolean): void {
    autosave = enabled; session?.persistence.setAutosave(enabled);
  },
  async checkpointDocument(): Promise<void> {
    await editor.settleComposition(); await current().checkpoint();
  },
  async retryPersistence(): Promise<void> {
    await editor.settleComposition(); await current().retryPersistence();
  },
  async prepareReplacement() {
    await editor.settleComposition(); editor.setReadOnly(true);
    try {
      await current().suspend();
      const intent = {...await current().closeIntent(true), discard: false};
      return { dirty: current().dirty, hasFile: current().status.file_ref !== null,
        label: current().status.label, intentJson: JSON.stringify(intent) };
    } catch (error) { editor.setReadOnly(false); current().resume(); throw error; }
  },
  async replacementIntent(discard: boolean): Promise<string> { return JSON.stringify(await current().closeIntent(discard)); },
  cancelReplacement(): void { editor.setReadOnly(false); session?.resume(); },
  async closeDocument(intentJson: string): Promise<void> { await current().closePrepared(JSON.parse(intentJson)); editor.destroy(); session = undefined; },
  snapshot: () => ({ ...editor.snapshot(), locale: currentLocale(), document: session?.status, dirty: session?.dirty, saving: session?.isSaving,
    ...session?.persistence.status }),
  // Isolated editor fixtures exercise the same engine; native document checks run
  // separately through the real Rust service and this document client.
  async verify() {
    const editorResult = await verifyEditor();
    const searchResult = await verifySearch();
    const markdownResult = await verifyMarkdown();
    const navigationResult = await verifyNavigation();
    const tableInsertionResult = await verifyTableInsertion();
    const themeResult = await verifyTheme();
    return { ...editorResult, passed: [...editorResult.passed, ...searchResult.passed, ...markdownResult.passed, ...navigationResult.passed, ...tableInsertionResult.passed, ...themeResult.passed],
      failed: [...editorResult.failed, ...searchResult.failed, ...markdownResult.failed, ...navigationResult.failed, ...tableInsertionResult.failed, ...themeResult.failed] };
  },
  verifyDocumentEdit: () => verifyDocumentEdit(editor),
};
Object.assign(window, { openTypora: api });
window.addEventListener('error', event => report(event.message));
window.addEventListener('unhandledrejection', event => report(formatError(event.reason)));
window.addEventListener('pagehide', () => { session?.destroy(); editor.destroy(); client.destroy(); }, { once: true });
void client.handshake().then(() => notifyHost({ kind: 'ready' })).catch(error => report(formatError(error)));
