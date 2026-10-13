import { editorCommands, type EditorCommand } from '@lino/protocol/editor-host';
import { hostGeneration, notifyHost } from '@lino/protocol/webkit';
import { DocumentClient } from '@lino/protocol/documents';
import { ClipboardClient } from '@lino/protocol/clipboard';
import { AssetsClient } from '@lino/protocol/assets';
import type { OpenedDocument } from '@lino/protocol/generated/OpenedDocument';
import type { DocumentStatus } from '@lino/protocol/generated/DocumentStatus';
import type { SaveTarget } from '@lino/protocol/generated/SaveTarget';
import type { PreferenceSnapshot } from '@lino/protocol/generated/PreferenceSnapshot';
import { PROTOCOL_VERSION, RESOURCE_VERSION } from '@lino/protocol/generated/version';
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
import { linePosition, navigateSourcePosition } from './features/navigation/line.ts';
import { previewSources } from './features/media/model.ts';
import { openLink } from './features/references/commands.ts';
import { ExportPlan } from './export/html.ts';
import './styles/editor.css';

setLocale(currentLocale());
const root = document.getElementById('editor')!;
const report = (message: string) => notifyHost({ kind: 'error', message });
const client = new DocumentClient(json => notifyHost({ kind: 'rpc', json }));
const clipboard = new ClipboardClient(notifyHost);
const assets = new AssetsClient(notifyHost);
let session: DocumentSession | undefined;
let autosave = false;
let preferences: PreferenceSnapshot | undefined;
let exportPlan: ExportPlan | undefined;
let editor = new MarkdownEditor(root, '', notifyHost, changed => session?.changed(changed), text => clipboard.write(text), assets, { nativeSearch: true });
editor.setReadOnly(true);
function publish(): void {
  assets.setDocument(session?.status.session_id ?? null, session?.status.file_ref ?? null);
  if (session) notifyHost({ kind: 'document', dirty: session.dirty, saving: session.isSaving,
    readOnly: session.status.read_only ?? false, sessionId: session.status.session_id, fileRef: session.status.file_ref,
    hasFile: session.status.file_ref !== null, label: session.status.label, revision: session.status.revision,
    ...session.persistence.status });
}
function current(): DocumentSession { if (!session) throw new Error(t('document.notLoaded')); return session; }
const api = {
  async exportIdentity() {
    await editor.settleResources(); await editor.settleComposition(); await current().flush();
    const owner = current();
    try {
      // Input stays editable; pause only acceptance until Rust captures R.
      await owner.captureExport();
      const { session_id, epoch, revision } = owner.status; return { session_id, epoch, revision };
    } catch (error) { owner.endExportCapture(); throw error; }
  },
  endExportCapture(): void { session?.endExportCapture(); },
  prepareExport(json: string) {
    exportPlan?.cancel(); exportPlan = new ExportPlan(JSON.parse(json));
    return { job_id: exportPlan.source.job_id, images: exportPlan.images };
  },
  async renderExport(job: string, resources: string, mathCSS: string): Promise<string> {
    const plan = exportPlan;
    if (!plan || plan.source.job_id !== job) throw new Error(t('export.cancelled'));
    const html = await plan.render(JSON.parse(resources), mathCSS);
    if (plan !== exportPlan) throw new Error(t('export.cancelled'));
    exportPlan = undefined; return html;
  },
  cancelExport(): void { exportPlan?.cancel(); exportPlan = undefined; },
  command(command: EditorCommand) {
    if (!editorCommands.includes(command)) throw new Error(t('editor.unknownCommand'));
    return editor.command(command);
  },
  searchInput(text: string, sequence: string, owner: string, generation: number): void {
    if (session?.status.session_id === owner && hostGeneration() === generation) editor.search(text, sequence);
  },
  navigateLine(line: number): boolean {
    const position = linePosition(editor.view.state, String(line));
    if (editor.composing()) throw new Error(t('editor.finishComposition'));
    if (position === null) throw new Error(t('navigation.invalid', { max: editor.view.state.doc.lines }));
    return navigateSourcePosition(editor.view, position);
  },
  navigateAnchor(anchor: string): boolean { return openLink(editor.view, '#' + anchor, error => report(formatError(error))); },
  receive: (json: string) => client.receive(json),
  receiveClipboard: (id: string, error: string | null) => clipboard.receive(id, error),
  receiveAsset: (id: string, value: string | null, error: string | null) => assets.receive(id, value, error),
  hasLocalImages: () => previewSources(editor.view.state).some(source => source.kind === 'image' && !/^https?:\/\//i.test(source.text)),
  setLocale(value: unknown): void { setLocale(value); publish(); },
  async prepareDocumentReadOnly() {
    await editor.settleResources(); await editor.settleComposition(); editor.setReadOnly(true);
    try { await current().flush(); const { session_id, epoch, revision } = current().status; return { session_id, epoch, revision }; }
    catch (error) { editor.setReadOnly(false); throw error; }
  },
  applyDocumentReadOnly(json: string): void {
    const status: DocumentStatus = JSON.parse(json);
    current().acceptReadOnly(status);
    editor.setDocumentReadOnly(status.read_only ?? false);
  },
  async applyPreferences(json: string): Promise<void> {
    const next: PreferenceSnapshot = JSON.parse(json);
    if (next.schema_version !== 1) throw new Error(t('document.protocolMismatch'));
    if (preferences && BigInt(next.revision) < BigInt(preferences.revision)) return;
    preferences = next;
    await editor.applyPreferences(next.values);
    if (preferences !== next) return;
    autosave = next.values.auto_save; session?.persistence.setAutosave(autosave); publish();
  },
  transportError: (id: string, message: string) => client.fail(id, message),
  async attachDocument(json: string): Promise<void> {
    const opened: OpenedDocument = JSON.parse(json);
    if (opened.protocol_version !== PROTOCOL_VERSION || opened.resource_version !== RESOURCE_VERSION) throw new Error(t('document.protocolMismatch'));
    const holder = document.createElement('div');
    assets.invalidate();
    assets.setDocument(opened.status.session_id, opened.status.file_ref);
    const next = new MarkdownEditor(holder, opened.text, notifyHost, changed => session?.changed(changed), text => clipboard.write(text), assets, { nativeSearch: true });
    session?.destroy(); editor.destroy(); root.replaceChildren(...Array.from(holder.childNodes)); editor = next;
    session = new DocumentSession(client, opened, editor, publish, report);
    editor.setDocumentReadOnly(opened.status.read_only ?? false);
    if (preferences) await editor.applyPreferences(preferences.values);
    session.persistence.setAutosave(autosave); publish();
  },
  async saveDocument(targetJson: string | null = null): Promise<void> {
    await editor.settleResources();
    await editor.settleComposition();
    const target: SaveTarget | null = targetJson === null ? null : JSON.parse(targetJson);
    await current().save(target);
    assets.invalidate();
    editor.refreshResources();
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
    await editor.settleResources();
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
Object.assign(window, { lino: api });
window.addEventListener('error', event => report(event.message));
window.addEventListener('unhandledrejection', event => report(formatError(event.reason)));
window.addEventListener('pagehide', () => { exportPlan?.cancel(); session?.destroy(); editor.destroy(); client.destroy(); clipboard.destroy(); assets.destroy(); }, { once: true });
void client.handshake().then(() => notifyHost({ kind: 'ready' })).catch(error => report(formatError(error)));
