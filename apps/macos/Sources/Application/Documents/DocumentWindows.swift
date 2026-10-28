import AppKit

/// One shared Rust runtime enforces file ownership; each window owns one view,
/// input history and lifecycle. AppKit supplies native document tabs.
@MainActor
final class DocumentWindows {
    private let verifying: Bool
    init(verifying: Bool = false) { self.verifying = verifying }
    let backend = DocumentBackend()
    lazy var navigation = NavigationCoordinator(backend: backend)
    private var openPaths: [ObjectIdentifier: String] = [:]
    private(set) var controllers: [EditorWindowController] = []
    private weak var lastActive: EditorWindowController?
    private var reopening: [String] = []
    private(set) var quitting = false
    var onDocumentPresented: (() -> Void)?
    var active: EditorWindowController? { controllers.first { $0.isActiveDocument } }
    private var openingOrigin: EditorWindowController? {
        active ?? lastActive.flatMap { $0.documents.closed ? nil : $0 } ?? controllers.last { !$0.documents.closed }
    }
    var restorationPaths: [String] { Array((UserDefaults.standard.stringArray(forKey: "documentSessionPaths") ?? []).prefix(32)) }

    @discardableResult
    func reopen() -> EditorWindowController? {
        guard !quitting else { return nil }
        let document = active.flatMap { $0.documents.closed ? nil : $0 } ?? controllers.first { !$0.documents.closed } ?? create()
        if document.documents.ready || document.isPreviewing, let window = document.window {
            window.tabGroup?.selectedWindow?.deminiaturize(nil)
            window.deminiaturize(nil)
            window.tabGroup?.selectedWindow = window
            document.showWindow(nil); window.makeKeyAndOrderFront(nil)
            onDocumentPresented?()
        }
        return document
    }

    @discardableResult
    func create(path: String? = nil, offerRecovery: Bool = false, line: Int? = nil, anchor: String? = nil, tabOrigin: EditorWindowController? = nil, filePreview: NativeFilePreview? = nil, newWindow: Bool = false) -> EditorWindowController {
        let origin = tabOrigin ?? openingOrigin
        let useTabs = !newWindow && origin != nil
        let controller = EditorWindowController(verifying: verifying, backend: backend, initialPath: path, offerRecovery: offerRecovery, navigation: navigation, filePreview: filePreview)
        // Explicit grouping belongs to the document-opening policy. System
        // preferences must not turn a regular open into a separate window.
        controller.window?.tabbingMode = verifying || newWindow ? .disallowed : .automatic
        if useTabs, let frame = origin?.window?.frame {
            // Establish final geometry BEFORE navigation, font measurement and
            // the first editor paint, rather than resizing the ready page.
            controller.window?.setFrame(frame, display: false)
            controller.window?.contentView?.layoutSubtreeIfNeeded()
        }
        controller.pendingNavigationLine = line
        controller.pendingNavigationAnchor = anchor
        controllers.append(controller)
        controller.onActivated = { [weak self, weak controller] in self?.lastActive = controller }
        controller.onClosed = { [weak self, weak controller] in
            guard let self, let controller else { return }
            if lastActive === controller { lastActive = nil }
            controller.detach(); controllers.removeAll { $0 === controller }; openPaths.removeValue(forKey: ObjectIdentifier(controller)); navigation.updateOpenFiles(Array(openPaths.values).sorted())
        }
        // Record the path before the Rust close releases its file binding.
        controller.onWillClose = { [weak self] path in
            guard let self, let path else { return }; reopening.append(path); reopening = Array(reopening.suffix(20))
        }
        controller.workspace.onOpen = { [weak self, weak controller] path, line in Task { await self?.open(path: path, line: line, origin: controller) } }
        controller.quickOpen.onOpen = controller.workspace.onOpen
        controller.workspace.onOpenDialog = { [weak self] in Task { await self?.openDialog() } }
        controller.onFileBindingChanged = { [weak self, weak controller] path in
            guard let self, let controller else { return }
            openPaths[ObjectIdentifier(controller)] = path
            navigation.updateOpenFiles(controllers.compactMap { openPaths[ObjectIdentifier($0)] })
            if let path, !verifying { NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: path)) }
        }
        controller.onOpenDocumentLink = { [weak self] path, anchor in Task { await self?.open(path: path, anchor: anchor) } }
        controller.bridge.onReady = { [weak self, weak controller, weak origin] in
            guard let controller else { return }
            Task {
                do {
                    try await controller.documents.initialize()
                    if useTabs, origin?.documents.closed == false, let old = origin?.window, let next = controller.window, old.tabbedWindows?.contains(where: { $0 === next }) != true {
                        old.deminiaturize(nil)
                        next.setFrame(old.frame, display: false); old.addTabbedWindow(next, ordered: .above)
                        next.tabGroup?.selectedWindow = next
                    }
                    controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
                    if self?.verifying == false { controller.window?.tabbingMode = .automatic }
                    self?.lastActive = controller
                    self?.onDocumentPresented?()
                    if controller.isActiveDocument && !controller.quickOpen.visible { _ = try await controller.bridge.call("focusEditor"); controller.window?.makeFirstResponder(controller.webView) }
                    if let path, self?.verifying == false { NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: path)) }
                    if let line = controller.pendingNavigationLine { _ = try await controller.bridge.call("navigateLine", arguments: [line]); controller.pendingNavigationLine = nil }
                    if let anchor = controller.pendingNavigationAnchor { _ = try await controller.bridge.call("navigateAnchor", arguments: [anchor]); controller.pendingNavigationAnchor = nil }
                } catch {
                    if path != nil && controller.documents.sessionId == nil {
                        controller.window?.close()
                        self?.showOpenError(error, path: path!, in: origin?.window)
                    } else { controller.showWindow(nil); self?.onDocumentPresented?(); controller.showError(userFacingError(error)) }
                }
            }
        }
        if filePreview != nil {
            if useTabs, let old = origin?.window, let next = controller.window {
                old.deminiaturize(nil)
                next.setFrame(old.frame, display: false); old.addTabbedWindow(next, ordered: .above); next.tabGroup?.selectedWindow = next
            }
            controller.showFilePreview()
            if !verifying { controller.window?.tabbingMode = .automatic }
            lastActive = controller
            onDocumentPresented?()
            return controller
        }
        // The first visible frame already contains the configured editor page.
        // Loading and wallpaper preparation happen before window/tab presentation.
        do { try controller.loadEditor() }
        catch { controller.showWindow(nil); onDocumentPresented?(); controller.showError(userFacingError(error)) }
        return controller
    }
    func open(path: String, line: Int? = nil, anchor: String? = nil, origin: EditorWindowController? = nil) async {
        guard !quitting else { return }
        let origin = origin ?? openingOrigin
        if let pending = controllers.first(where: { $0.documents.openingPath == path && !$0.documents.ready && !$0.documents.closed }) {
            pending.pendingNavigationLine = line; pending.pendingNavigationAnchor = anchor; return
        }
        do {
            if NativeFilePreview.accepts(path) {
                let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                if let existing = controllers.first(where: { $0.filePreview?.url.resolvingSymlinksInPath() == resolved }) {
                    existing.window?.tabGroup?.selectedWindow = existing.window
                    existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
                    onDocumentPresented?()
                    await navigation.noteFile(existing.filePreview!.url.path)
                } else {
                    let preview = try NativeFilePreview(url: resolved)
                    let canonical = await navigation.noteFile(resolved.path) ?? resolved.path
                    preview.bindCanonicalURL(URL(fileURLWithPath: canonical))
                    create(path: canonical, tabOrigin: origin, filePreview: preview)
                }
                if !verifying { NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: path)) }
                return
            }
            try await backend.perform { try $0.validateDocumentFile(path: path) }
            if let session = try await backend.perform({ try $0.fileSession(path: path) }),
               let existing = controllers.first(where: { $0.documents.sessionId == session }) {
                if let window = existing.window { window.tabGroup?.selectedWindow = window }
                existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil)
                onDocumentPresented?()
                existing.window?.makeFirstResponder(existing.webView)
                _ = try? await existing.bridge.call("focusEditor")
                await navigation.noteFile(path)
                if let line, existing.documents.ready { _ = try await existing.bridge.call("navigateLine", arguments: [line]) }
                else { existing.pendingNavigationLine = line }
                if let anchor, existing.documents.ready { _ = try await existing.bridge.call("navigateAnchor", arguments: [anchor]) }
                else { existing.pendingNavigationAnchor = anchor }
                return
            }
            if let empty = origin ?? active, (empty.window?.tabbedWindows?.count ?? 1) <= 1,
               try await empty.documents.openIfEmpty(path: path) {
                empty.showWindow(nil)
                empty.window?.makeKeyAndOrderFront(nil)
                if let line { _ = try await empty.bridge.call("navigateLine", arguments: [line]) }
                if let anchor { _ = try await empty.bridge.call("navigateAnchor", arguments: [anchor]) }
                empty.window?.makeFirstResponder(empty.webView)
                _ = try await empty.bridge.call("focusEditor")
                await navigation.noteFile(path)
                lastActive = empty
                onDocumentPresented?()
                return
            }
            create(path: path, line: line, anchor: anchor, tabOrigin: origin)
        } catch { showOpenError(error, path: path, in: (origin ?? active)?.window) }
    }
    func openDialog(in window: NSWindow? = nil) async {
        guard !quitting else { return }
        let origin = openingOrigin
        guard let url = await DocumentDialogs.open(in: window ?? origin?.window) else { return }
        await open(path: url.path, origin: origin)
    }
    private func showOpenError(_ error: Error, path: String, in window: NSWindow?) {
        let alert = NSAlert(); alert.messageText = localized("dialog.openFailed", URL(fileURLWithPath: path).lastPathComponent)
        alert.informativeText = userFacingError(error); alert.addButton(withTitle: localized("button.ok"))
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
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
        let targets = controllers.filter { !$0.isPreviewing && !$0.documents.closed }
        var paths = controllers.compactMap { $0.filePreview?.url.path }
        let closed = await closeDocumentGroup(targets.map { $0.documents! }) {
            // Save decisions may bind previously untitled documents. Capture
            // restoration paths after preparation, while all views are frozen.
            for controller in targets {
                guard let id = controller.documents.sessionId else { continue }
                do {
                    if let path = try await self.backend.perform({ try $0.documentPath(sessionId: id) }) { paths.append(path) }
                } catch { controller.showError(userFacingError(error)); return false }
            }
            return true
        }
        guard closed else { return false }
        UserDefaults.standard.set(paths, forKey: "documentSessionPaths")
        return true
    }
    func detach() { for controller in controllers { controller.detach() }; navigation.detach() }
}
