import { EditorView } from '@codemirror/view';
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
import { verifyMediaLayout } from './features/media/verification.ts';
import { verifyTableInsertion } from './features/tables/verification.ts';
import { currentLocale, setLocale, t } from './localization/index.ts';
import { formatError } from './localization/errors.ts';
import { linePosition, navigateSourcePosition } from './features/navigation/line.ts';
import { previewSources } from './features/media/model.ts';
import { openLink } from './features/references/commands.ts';
import { imageSizes } from './features/media/state.ts';
import { selectedTheme } from './themes/catalog.ts';
import { ExportPlan, type ExportPresentation } from './export/html.ts';
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
let exportAppearance: 'light' | 'dark' = 'light';
let exportPresentation: ExportPresentation = {};
// Window geometry belongs to the host view, and survives document replacement.
let viewportWidth = (window as Window & { __linoViewportWidth?: number }).__linoViewportWidth;
let viewportSequence = -1n;
let editor = new MarkdownEditor(root, '', notifyHost, changed => session?.changed(changed), text => clipboard.write(text), assets, { nativeSearch: true, nativeAnalysis: true });
if (viewportWidth !== undefined) editor.setViewportWidth(viewportWidth);
editor.setReadOnly(true);
let backgroundAsset = '';
let backgroundReady: Promise<void> = Promise.resolve();
function applyBackground(): void {
  if (!preferences) return;
  const values = preferences.values;
  editor.view.dom.dataset.backgroundImage = String(Boolean(values.background_image));
  editor.view.dom.style.setProperty('--ot-background-image', values.background_image ? `url("ot-appearance://local/background?asset=${encodeURIComponent(values.background_image)}")` : 'none');
  editor.view.dom.style.setProperty('--ot-background-image-opacity', String(values.background_opacity / 100));
  if (backgroundAsset !== values.background_image) {
    backgroundAsset = values.background_image;
    const asset = backgroundAsset;
    if (asset) {
      const image = new Image(); image.src = `ot-appearance://local/background?asset=${encodeURIComponent(asset)}`;
      backgroundReady = image.decode().catch(() => { if (backgroundAsset === asset) report(t('editor.backgroundUnavailable')); });
    } else backgroundReady = Promise.resolve();
  }
}
function publish(): void {
  assets.setDocument(session?.status.session_id ?? null, session?.status.file_ref ?? null);
  if (session) notifyHost({ kind: 'document', dirty: session.dirty, saving: session.isSaving,
    readOnly: session.status.read_only ?? false, sessionId: session.status.session_id, fileRef: session.status.file_ref,
    hasFile: session.status.file_ref !== null, label: session.status.label, revision: session.status.revision,
    ...session.persistence.status });
}
function current(): DocumentSession { if (!session) throw new Error(t('document.notLoaded')); return session; }
// WKWebView's private content view may receive file drags before its parent.
// Forward trusted drop coordinates and names; native code reads the drag board,
// authorizes actual file URLs, and reuses the same import path as AppKit drops.
root.addEventListener('dragover', event => {
  if (event.dataTransfer?.types.includes('Files') && !editor.view.state.readOnly && !editor.composing()) { event.preventDefault(); event.dataTransfer.dropEffect = 'copy'; }
});
root.addEventListener('drop', event => {
  const images = Array.from(event.dataTransfer?.files ?? []).filter(file => file.type.startsWith('image/') || /\.(png|jpe?g|gif|webp|tiff?|bmp|svg|heic|heif|avif)$/i.test(file.name));
  if (!event.isTrusted || !images.length || editor.view.state.readOnly || editor.composing()) return;
  event.preventDefault(); event.stopPropagation();
  notifyHost({ kind: 'image-drop', names: images.slice(0, 32).map(file => file.name), x: event.clientX, y: event.clientY });
}, true);
const api = {
  async exportIdentity() {
    await editor.settleResources(); await editor.settleComposition(); await current().flush();
    const owner = current();
    try {
      // Input stays editable; pause only acceptance until Rust captures R.
      const capture = owner.captureExport();
      exportAppearance = editor.appearance();
      const style = getComputedStyle(editor.view.contentDOM), rect = editor.view.contentDOM.getBoundingClientRect();
      exportPresentation = { fontSize: parseFloat(style.fontSize), contentWidth: rect.width, padding: parseFloat(style.paddingLeft),
        imageScales: new Map([...editor.view.state.field(imageSizes)].map(([from, entry]) => [from, entry.scale])) };
      await capture;
      const { session_id, epoch, revision } = owner.status; return { session_id, epoch, revision };
    } catch (error) { owner.endExportCapture(); throw error; }
  },
  endExportCapture(): void { session?.endExportCapture(); },
  prepareExport(json: string) {
    const source = JSON.parse(json);
    source.preferences.theme = exportAppearance;
    exportPlan?.cancel(); exportPlan = new ExportPlan(source, undefined, exportPresentation);
    return { job_id: exportPlan.source.job_id, images: exportPlan.images, background_color: selectedTheme(source.preferences)[exportAppearance].colors.bg };
  },
  async renderExport(job: string, resources: string, mathCSS: string, background = '', widths = '{}'): Promise<string> {
    const plan = exportPlan;
    if (!plan || plan.source.job_id !== job) throw new Error(t('export.cancelled'));
    const html = await plan.render(JSON.parse(resources), mathCSS, background, JSON.parse(widths));
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
  navigateHeading(from: number, token: string): boolean {
    return editor.acceptsHeading(from, token) && navigateSourcePosition(editor.view, from);
  },
  setOutlineVisible(visible: boolean, sequence: string, owner: string, generation: number): void {
    if (session?.status.session_id === owner && hostGeneration() === generation) editor.setOutlineVisible(visible, sequence);
  },
  continueOutline(): void { editor.continueOutline(); },
  prepareImageDrop: (x: number, y: number) => editor.prepareImageDrop(x, y),
  cancelImageDrop: () => editor.cancelImageDrop(),
  commitImageDrop: (paths: string[]) => editor.commitImageDrop(paths),
  formatFailure: (error: unknown) => formatError(error),
  focusEditor(): void { editor.view.focus(); },
  async preparePresentation(): Promise<void> { await backgroundReady; await document.fonts.ready; },
  setViewportWidth(width: number, sequence: string, generation: number): void {
    if (hostGeneration() !== generation || !Number.isFinite(width) || width <= 0 || !/^\d+$/.test(sequence)) return;
    const next = BigInt(sequence);
    if (next <= viewportSequence) return;
    viewportSequence = next; viewportWidth = width; editor.setViewportWidth(width);
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
    applyBackground();
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
    const next = new MarkdownEditor(holder, opened.text, notifyHost, changed => session?.changed(changed), text => clipboard.write(text), assets, { nativeSearch: true, nativeAnalysis: true });
    if (viewportWidth !== undefined) next.setViewportWidth(viewportWidth);
    session?.destroy(); editor.destroy(); root.replaceChildren(...Array.from(holder.childNodes)); editor = next;
    session = new DocumentSession(client, opened, editor, publish, report);
    editor.setDocumentReadOnly(opened.status.read_only ?? false);
    if (preferences) { applyBackground(); await editor.applyPreferences(preferences.values); }
    session.persistence.setAutosave(autosave); publish();
  },
  async saveDocument(targetJson: string | null = null): Promise<void> {
    await editor.settleResources();
    await editor.settleComposition();
    const target: SaveTarget | null = targetJson === null ? null : JSON.parse(targetJson);
    const binding = current().status.file_ref;
    await current().save(target);
    if (binding !== current().status.file_ref) editor.refreshResources();
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
        replaceableEmpty: editor.canReplaceEmpty(),
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
  // Hidden WKWebViews suspend animation frames. Coordinate reads flush the
  // same pending CM measurements that a visible frame normally performs.
  measureDocumentForVerification() {
    for (const dom of document.querySelectorAll<HTMLElement>('.cm-editor')) {
      const view = EditorView.findFromDOM(dom);
      if (view) view.coordsAtPos(view.viewport.from);
    }
  },
  setCodeLanguageDraftForVerification(text: string) {
    const input = document.querySelector<HTMLElement>('[data-code-language-input]');
    const picker = input && EditorView.findFromDOM(input);
    if (!picker) throw new Error('Code language picker is not open');
    picker.dispatch({ changes: { from: 0, to: picker.state.doc.length, insert: text },
      selection: { anchor: text.length }, userEvent: 'input.type' });
  },
  verifyDocumentEdit: () => verifyDocumentEdit(editor),
  verifyMediaLayout,
};
Object.assign(window, { lino: api });
window.addEventListener('error', event => report(event.message));
window.addEventListener('unhandledrejection', event => report(formatError(event.reason)));
window.addEventListener('pagehide', () => { exportPlan?.cancel(); session?.destroy(); editor.destroy(); client.destroy(); clipboard.destroy(); assets.destroy(); }, { once: true });
void client.handshake().then(() => notifyHost({ kind: 'ready' })).catch(error => report(formatError(error)));
