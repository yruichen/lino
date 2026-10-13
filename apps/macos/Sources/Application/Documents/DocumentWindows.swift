import AppKit

/// One shared Rust runtime enforces file ownership; each window owns one view,
/// input history and lifecycle. AppKit supplies native document tabs.
@MainActor
final class DocumentWindows {
    let backend = DocumentBackend()
    private(set) var controllers: [EditorWindowController] = []
    private var reopening: [String] = []
    private(set) var quitting = false
    var active: EditorWindowController? { controllers.first { $0.isActiveDocument } }
    var restorationPaths: [String] { Array((UserDefaults.standard.stringArray(forKey: "documentSessionPaths") ?? []).prefix(32)) }

    @discardableResult
    func create(path: String? = nil, offerRecovery: Bool = false, line: Int? = nil, anchor: String? = nil) -> EditorWindowController {
        let inheritedRoot = active?.workspace.currentRoot
        let controller = EditorWindowController(backend: backend, initialPath: path, offerRecovery: offerRecovery)
        controller.pendingNavigationLine = line
        controller.pendingNavigationAnchor = anchor
        controllers.append(controller)
        controller.onClosed = { [weak self, weak controller] in
            guard let self, let controller else { return }
            controller.detach(); controllers.removeAll { $0 === controller }
        }
        // Record the path before the Rust close releases its file binding.
        controller.onWillClose = { [weak self] path in
            guard let self, let path else { return }; reopening.append(path); reopening = Array(reopening.suffix(20))
        }
        controller.workspace.onOpen = { [weak self] path, line in Task { await self?.open(path: path, line: line) } }
        controller.onOpenDocumentLink = { [weak self] path, anchor in Task { await self?.open(path: path, anchor: anchor) } }
        controller.bridge.onReady = { [weak controller] in
            guard let controller else { return }
            Task {
                do {
                    try await controller.documents.initialize()
                    if let path { NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: path)) }
                    if let line = controller.pendingNavigationLine { _ = try await controller.bridge.call("navigateLine", arguments: [line]); controller.pendingNavigationLine = nil }
                    if let anchor = controller.pendingNavigationAnchor { _ = try await controller.bridge.call("navigateAnchor", arguments: [anchor]); controller.pendingNavigationAnchor = nil }
                } catch { controller.showError(error.localizedDescription) }
            }
        }
        controller.showWindow(nil)
        if let inheritedRoot { Task { await controller.workspace.inheritRoot(inheritedRoot) } }
        do { try controller.loadEditor() } catch { controller.showError(error.localizedDescription) }
        return controller
    }
    func open(path: String, line: Int? = nil, anchor: String? = nil) async {
        guard !quitting else { return }
        if let pending = controllers.first(where: { $0.documents.openingPath == path && !$0.documents.ready && !$0.documents.closed }) {
            pending.pendingNavigationLine = line; pending.pendingNavigationAnchor = anchor; pending.showWindow(nil); return
        }
        do {
            if let session = try await backend.perform({ try $0.fileSession(path: path) }),
               let existing = controllers.first(where: { $0.documents.sessionId == session }) {
                existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
                if let line, existing.documents.ready { _ = try await existing.bridge.call("navigateLine", arguments: [line]) }
                else { existing.pendingNavigationLine = line }
                if let anchor, existing.documents.ready { _ = try await existing.bridge.call("navigateAnchor", arguments: [anchor]) }
                else { existing.pendingNavigationAnchor = anchor }
                return
            }
            create(path: path, line: line, anchor: anchor)
        } catch { active?.showError(error.localizedDescription) }
    }
    func openDialog() async {
        guard !quitting else { return }
        let controller = active ?? create()
        guard let window = controller.window, let url = await DocumentDialogs.open(in: window) else { return }
        await open(path: url.path)
    }
    func reopenClosed() async { if let path = reopening.popLast() { await open(path: path) } }
    func saveAll() async {
        for controller in controllers where controller.documents.ready && !controller.documents.closed {
            if !(await controller.documents.save()) { return }
        }
    }
    func terminate() async -> Bool {
        guard !quitting else { return false }
        quitting = true
        defer { quitting = false }
        let targets = controllers.filter { !$0.documents.closed }
        var paths: [String] = []
        let closed = await closeDocumentGroup(targets.map { $0.documents! }) {
            // Save decisions may bind previously untitled documents. Capture
            // restoration paths after preparation, while all views are frozen.
            for controller in targets {
                guard let id = controller.documents.sessionId else { continue }
                do {
                    if let path = try await self.backend.perform({ try $0.documentPath(sessionId: id) }) { paths.append(path) }
                } catch { controller.showError(error.localizedDescription); return false }
            }
            return true
        }
        guard closed else { return false }
        UserDefaults.standard.set(paths, forKey: "documentSessionPaths")
        return true
    }
    func detach() { for controller in controllers { controller.detach() } }
}
