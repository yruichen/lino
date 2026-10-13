import AppKit
import WebKit

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation, NSMenuItemValidation {
    let bridge: EditorBridge
    let webView: WKWebView
    private let imageResources: ImageResources
    private var assetActions: AssetActions!
    private var externalChanges: ExternalChanges!
    private var externalState = "unchanged"
    var pendingNavigationAnchor: String?
    var onOpenDocumentLink: ((String, String?) -> Void)? {
        didSet { assetActions?.onOpenDocument = onOpenDocumentLink }
    }
    private(set) var editorMode = "visual"
    private let statusLabel = NSTextField(labelWithString: localized("status.loading"))
    private let stateIcon = NSImageView()
    private let detailLabel = NSTextField(labelWithString: localized("status.markdownEncoding"))
    private let retryButton = NSButton(title: localized("status.retry"), target: nil, action: nil)
    private(set) var workspace: WorkspaceController!
    private(set) var exports: ExportCoordinator!
    private(set) var searchControls: DocumentSearchController!
    private var documentDetail = localized("status.markdownEncoding")
    private var workspaceVisible: Bool { sidebarItem?.isCollapsed == false }
    private let splitController = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem?
    private let sidebarContainer = NSVisualEffectView()
    var onWillClose: ((String?) -> Void)?
    var pendingNavigationLine: Int?
    private var writingStatus: [String: Any] = [:]
    private(set) var documents: DocumentActions!
    private var documentMessage = localized("status.loading")
    private var composing = false
    private var inCodeBlock = false
    private var codeFenced = false
    private var codeCanIndent = false
    private var documentStatus: [String: Any]?
    private var noticeKey: String?
    private var errorMessage: String?
    private var persistenceError: String?
    private var automaticReconnectUsed = false
    var onClosed: (() -> Void)?
    private(set) var canUndo = false
    private(set) var canRedo = false

    init(verifying: Bool = false, backend: DocumentBackend = DocumentBackend(), initialPath: String? = nil, offerRecovery: Bool = true) {
        bridge = EditorBridge(backend: backend)
        let imageBridge = bridge
        imageResources = ImageResources(backend: backend, session: { [weak imageBridge] in imageBridge?.sessionId })
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(imageResources, forURLScheme: "ot-image")
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isHidden = true
        // Keep the painted loading surface inside the content area. AppKit
        // owns the separate titlebar, window buttons and unified toolbar.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = localized("document.untitled"); window.subtitle = "Lino"
        window.minSize = NSSize(width: 640, height: 420)
        window.toolbarStyle = .unified
        window.tabbingIdentifier = "LinoDocuments"
        window.tabbingMode = verifying ? .disallowed : .preferred
        window.center()
        super.init(window: window)
        documents = DocumentActions(bridge: bridge, window: window, verifying: verifying, initialPath: initialPath, offerRecovery: offerRecovery)
        exports = ExportCoordinator(bridge: bridge, window: window)
        exports.onError = { [weak self] message in self?.showError(message) }
        exports.onNotice = { [weak self] key in self?.showNotice(key) }
        externalChanges = ExternalChanges(bridge: bridge)
        externalChanges.onError = { [weak self] message in self?.showError(message) }
        externalChanges.onChange = { [weak self] state in
            guard let self else { return }; externalState = state; updateStatus()
        }
        assetActions = AssetActions(bridge: bridge, documents: documents, window: window)
        bridge.onAssetOperation = { [weak self] id, operation, payload, fileRef, sessionId in self?.assetActions.request(id: id, operation: operation, payload: payload, fileRef: fileRef, sessionId: sessionId) }
        workspace = WorkspaceController(backend: backend, window: window, verifying: verifying)
        workspace.onError = { [weak self] message in self?.showError(message) }
        workspace.onVisibility = { [weak self] visible in self?.setWorkspaceVisible(visible) }
        searchControls = DocumentSearchController(bridge: bridge)
        searchControls.canSearch = { [weak self] in self?.documents.ready == true && self?.composing == false }
        window.delegate = self
        bridge.webView = webView
        configuration.userContentController.add(bridge, name: "editor")
        webView.navigationDelegate = bridge
        webView.setAccessibilityLabel(localized("editor.accessibility"))
        let toolbar = NSToolbar(identifier: "document")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        configureContent(in: window)
        documents.onAvailabilityChanged = { [weak self] in
            guard let self else { return }
            webView.isHidden = !documents.ready
            searchControls.updateAvailability()
            window.toolbar?.validateVisibleItems()
            updateStatus()
        }
        documents.onOperationStarted = { [weak self] in self?.errorMessage = nil; self?.noticeKey = nil; self?.updateStatus() }
        documents.onReattached = { [weak self] in self?.showNotice("status.reconnected") }
        bridge.onStatus = { [weak self] status in
            guard let self else { return }
            canUndo = status["canUndo"] as? Bool == true && status["composing"] as? Bool != true
            canRedo = status["canRedo"] as? Bool == true && status["composing"] as? Bool != true
            editorMode = status["mode"] as? String == "source" ? "source" : "visual"
            composing = status["composing"] as? Bool == true
            writingStatus = status
            if let search = status["search"] as? [String: Any] { searchControls.apply(search) }
            inCodeBlock = status["codeBlock"] as? Bool == true
            codeFenced = status["codeFenced"] as? Bool == true
            codeCanIndent = status["codeCanIndent"] as? Bool == true
            updateStatus()
        }
        bridge.onDocument = { [weak self] status in self?.updateDocument(status) }
        bridge.onError = { [weak self] message in self?.showError(message) }
        bridge.onContextMenu = { [weak self] context, x, y in self?.showComponentMenu(context, x: x, y: y) }
        bridge.onTerminated = { [weak self] in self?.contentProcessTerminated() }
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    private func configureContent(in window: NSWindow) {
        let content = EditorSurfaceView(editor: webView)
        window.contentView = content
        let footer = NSVisualEffectView()
        footer.material = .headerView; footer.blendingMode = .withinWindow
        footer.state = .followsWindowActiveState
        stateIcon.image = NSImage(systemSymbolName: "circle.dotted", accessibilityDescription: nil)
        stateIcon.contentTintColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        retryButton.bezelStyle = .inline
        retryButton.controlSize = .small
        retryButton.target = self; retryButton.action = #selector(retry)
        retryButton.isHidden = true
        retryButton.setAccessibilityLabel(localized("status.retryAccessibility"))
        let row = NSStackView(views: [stateIcon, statusLabel, retryButton, NSView(), detailLabel])
        row.spacing = 8; row.alignment = .centerY
        sidebarContainer.material = .sidebar; sidebarContainer.blendingMode = .behindWindow
        sidebarContainer.state = .followsWindowActiveState
        let sidebarController = NSViewController(); sidebarController.view = sidebarContainer
        sidebarContainer.addSubview(workspace.view)
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebar.minimumThickness = 230; sidebar.maximumThickness = 420
        sidebar.preferredThicknessFraction = 0.26; sidebar.canCollapse = true; sidebar.isCollapsed = true
        sidebarItem = sidebar
        let editorController = NSViewController(); editorController.view = webView
        let editorItem = NSSplitViewItem(viewController: editorController); editorItem.minimumThickness = 320
        splitController.splitView.isVertical = true; splitController.splitView.dividerStyle = .thin
        splitController.addSplitViewItem(sidebar); splitController.addSplitViewItem(editorItem)
        for view in [splitController.view, footer, row, workspace.view] { view.translatesAutoresizingMaskIntoConstraints = false }
        content.addSubview(splitController.view); content.addSubview(footer); footer.addSubview(row)
        NSLayoutConstraint.activate([
            splitController.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            splitController.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            splitController.view.topAnchor.constraint(equalTo: content.topAnchor),
            splitController.view.bottomAnchor.constraint(equalTo: footer.topAnchor),
            workspace.view.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            workspace.view.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            workspace.view.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            workspace.view.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 30),
            row.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            stateIcon.widthAnchor.constraint(equalToConstant: 13),
            stateIcon.heightAnchor.constraint(equalToConstant: 13),
        ])
    }

    private func updateDocument(_ status: [String: Any]) {
        if let previous = documentStatus?["sessionId"] as? String, status["sessionId"] as? String != previous { searchControls.reset() }
        documentStatus = status
        let dirty = status["dirty"] as? Bool == true
        let saving = status["saving"] as? Bool == true
        documents.hasFile = status["hasFile"] as? Bool == true
        documents.label = status["label"] as? String
        documents.fileRef = status["fileRef"] as? String
        documents.readOnly = status["readOnly"] as? Bool == true
        externalChanges.bind(session: status["sessionId"] as? String, file: documents.fileRef)
        window?.title = documents.label ?? localized("document.untitled")
        window?.isDocumentEdited = dirty
        persistenceError = status["recoveryError"] as? String ?? status["autosaveError"] as? String
        if saving { documentMessage = localized("status.saving") }
        else if dirty {
            switch status["recoveryState"] as? String {
            case "saved": documentMessage = localized("status.dirtyProtected")
            case "saving": documentMessage = localized("status.dirtyProtecting")
            default: documentMessage = localized("status.dirty")
            }
        } else { documentMessage = documents.hasFile ? localized("status.saved") : localized("status.untitled") }
        documentDetail = status["autosave"] as? Bool == true ? localized("status.autosaveEncoding") : localized("status.markdownEncoding")
        updateStatus()
    }

    func setWorkspaceVisible(_ value: Bool) {
        guard let sidebarItem else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            sidebarItem.animator().isCollapsed = !value
        }
    }
    @objc func toggleWorkspace() { setWorkspaceVisible(!workspaceVisible) }
    func writingMenuState(_ command: String) -> NSControl.StateValue {
        let key = ["toggle-outline": "outline", "toggle-statistics": "statistics", "focus-mode": "focus", "typewriter-mode": "typewriter", "code-wrap": "codeWrap", "code-line-numbers": "codeNumbers"][command]
        return key.flatMap { writingStatus[$0] as? Bool } == true ? .on : .off
    }
    func showError(_ message: String) { errorMessage = message; noticeKey = nil; updateStatus() }
    private func showNotice(_ key: String) { noticeKey = key; errorMessage = nil; updateStatus() }

    func relocalize() {
        workspace.relocalize()
        webView.setAccessibilityLabel(localized("editor.accessibility"))
        retryButton.setAccessibilityLabel(localized("status.retryAccessibility"))
        for item in window?.toolbar?.items ?? [] { localizeToolbarItem(item) }
        if let documentStatus { updateDocument(documentStatus) }
        else { documentMessage = localized("status.loading"); updateStatus() }
    }
    private func updateStatus() {
        let zoom = (writingStatus["zoom"] as? Double) ?? 1
        detailLabel.stringValue = "\(Int((zoom * 100).rounded()))% · \(documentDetail)"
        let error = (persistenceError ?? errorMessage).map { localized("status.errorDetail", $0) } ?? noticeKey.map { localized($0) }
        let external = externalState == "changed" ? localized("status.externalChanged") : externalState == "deleted" ? localized("status.externalDeleted") : ""
        statusLabel.stringValue = error ?? [external.isEmpty ? documentMessage : external, documents.readOnly ? localized("status.readOnly") : "", composing ? localized("status.composing") : ""].filter { !$0.isEmpty }.joined(separator: " · ")
        statusLabel.toolTip = statusLabel.stringValue
        statusLabel.textColor = error == nil ? .secondaryLabelColor : .systemOrange
        stateIcon.image = NSImage(systemSymbolName: error == nil ? "checkmark.circle" : "exclamationmark.triangle", accessibilityDescription: error == nil ? localized("status.documentAccessibility") : localized("status.errorAccessibility"))
        stateIcon.contentTintColor = error == nil ? .secondaryLabelColor : .systemOrange
        retryButton.isHidden = persistenceError == nil && documents.ready
        retryButton.title = documents.ready ? localized("status.retry") : localized("status.reconnect")
    }

    func loadEditor() throws {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Editor", isDirectory: true) else {
            throw NSError(domain: "Lino", code: 1, userInfo: [NSLocalizedDescriptionKey: localized("error.missingResources")])
        }
        bridge.beginNavigation()
        imageResources.cancelAll()
        webView.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
    }

    private func contentProcessTerminated() {
        documents.viewTerminated(); canUndo = false; canRedo = false
        showNotice("status.processExited")
        guard !automaticReconnectUsed else {
            showNotice("status.processExitedAgain")
            return
        }
        automaticReconnectUsed = true
        do { try loadEditor() } catch { showError(error.localizedDescription) }
    }

    func reconnect() {
        guard !documents.ready && !documents.busy else { return }
        automaticReconnectUsed = false
        do { try loadEditor() } catch { showError(error.localizedDescription) }
    }

    func detach() {
        exports.detach()
        externalChanges.detach()
        imageResources.cancelAll(); bridge.onAssetOperation = nil
        bridge.onContextMenu = nil
        workspace.detach()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "editor")
        webView.navigationDelegate = nil; webView.stopLoading()
    }
    func windowWillClose(_ notification: Notification) { onClosed?() }
    func windowDidBecomeKey(_ notification: Notification) { externalChanges?.check() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if documents.closed { return true }
        Task { [weak self] in
            guard let self else { return }
            let path: String?
            if let id = documents.sessionId { path = try? await bridge.backend.perform { try $0.documentPath(sessionId: id) } } else { path = nil }
            if await documents.close() { onWillClose?(path); sender.performClose(nil) }
        }
        return false
    }
    var isActiveDocument: Bool { window != nil && NSApp.keyWindow === window && window?.attachedSheet == nil }
    var editorHasKeyboardFocus: Bool {
        guard isActiveDocument, let responder = window?.firstResponder as? NSView else { return false }
        return responder === webView || responder.isDescendant(of: webView)
    }
    func allowsCommand(_ command: String, fromToolbar: Bool = false) -> Bool {
        guard documents.ready, isActiveDocument else { return false }
        if ["visual", "source", "toggle-source", "find", "replace", "find-next", "find-previous", "toggle-find", "close-find", "goto-line", "toggle-outline", "toggle-statistics", "focus-mode", "typewriter-mode", "zoom-in", "zoom-out", "zoom-reset"].contains(command) { return true }
        if documents.readOnly && !["code-copy", "code-line-numbers", "code-wrap", "image-smaller", "image-larger", "image-reset-size", "image-reveal", "image-copy", "open-link", "copy-link", "goto-footnote", "preview-copy-source", "preview-copy-mathml", "preview-copy-svg", "preview-save-svg", "preview-refresh", "preview-cancel"].contains(command) { return false }
        if command != "code-block" && command.hasPrefix("code-") {
            if !inCodeBlock || (command == "code-language" && !codeFenced) { return false }
            if ["code-indent", "code-outdent"].contains(command) && !codeCanIndent { return false }
        }
        return !composing && (fromToolbar || editorHasKeyboardFocus)
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { documents.ready && isActiveDocument }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let command = item.representedObject as? String else { return documents.ready && isActiveDocument }
        item.state = writingMenuState(command)
        return allowsCommand(command, fromToolbar: true)
    }
    func performEditorCommand(_ command: String) {
        if command == "find" || command == "replace" { searchControls.open(replacing: command == "replace") }
        else { bridge.command(command) }
    }
    @objc func formatAction(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? String, allowsCommand(command, fromToolbar: true) { bridge.command(command) }
    }
    @objc private func retry() {
        if documents.ready { Task { await documents.retryPersistence() } }
        else { reconnect() }
    }
}
