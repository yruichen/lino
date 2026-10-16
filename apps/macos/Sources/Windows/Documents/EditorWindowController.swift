import AppKit
import WebKit

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation, NSMenuItemValidation {
    let bridge: EditorBridge
    let webView: EditorWebView
    let filePreview: NativeFilePreview?
    var isPreviewing: Bool { filePreview != nil }
    private let imageResources: ImageResources
    private var assetActions: AssetActions!
    private var externalChanges: ExternalChanges!
    private(set) var externalState = "unchanged"
    var pendingNavigationAnchor: String?
    var onOpenDocumentLink: ((String, String?) -> Void)? {
        didSet { assetActions?.onOpenDocument = onOpenDocumentLink }
    }
    private(set) var editorMode = "visual"
    let titleField = NSTextField(labelWithString: localized("document.untitled"))
    private let statusLabel = NSTextField(labelWithString: localized("status.loading"))
    private let stateIcon = NSImageView()
    private let statisticsLabel = NSTextField(labelWithString: "")
    private let navigation: NavigationCoordinator
    private let verifying: Bool
    private var synchronizingTabLayouts = false
    private var sidebarObserver: UUID?
    private var desiredSidebar = false
    private lazy var viewport = EditorViewport(bridge: bridge)
    private var restoreEditorAfterSidebar = false
    private let footer = NSVisualEffectView()
    private(set) var quickOpen: QuickOpenController!
    private var customization: SidebarCustomizationController!
    var onFileBindingChanged: ((String?) -> Void)?
    private var boundFileRef: String?
    private var bindingTask: Task<Void, Never>?
    private let detailLabel = NSTextField(labelWithString: localized("status.markdownEncoding"))
    private let retryButton = NSButton(title: localized("status.retry"), target: nil, action: nil)
    private(set) var workspace: WorkspaceController!
    private(set) var exports: ExportCoordinator!
    private(set) var searchControls: DocumentSearchController!
    private var documentDetail = localized("status.markdownEncoding")
    var workspaceVisible: Bool { desiredSidebar }
    let navigationSplit = NavigationSplitView()
    private let navigationController = NSSplitViewController()
    private let sidebarContainer = NativeMaterialSurface()
    var onWillClose: ((String?) -> Void)?
    var pendingNavigationLine: Int?
    private var outlineSequence: UInt64 = 0
    private var outlineRequest: (generation: Int, session: String, visible: Bool)?
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
    var onActivated: (() -> Void)?
    private(set) var canUndo = false
    private(set) var canRedo = false

    init(verifying: Bool = false, backend: DocumentBackend = DocumentBackend(), initialPath: String? = nil, offerRecovery: Bool = true, navigation: NavigationCoordinator? = nil, filePreview: NativeFilePreview? = nil) {
        self.verifying = verifying
        self.filePreview = filePreview
        self.navigation = navigation ?? NavigationCoordinator(backend: backend)
        desiredSidebar = self.navigation.sidebar.values.visible
        bridge = EditorBridge(backend: backend)
        let imageBridge = bridge
        imageResources = ImageResources(backend: backend, session: { [weak imageBridge] in imageBridge?.sessionId })
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(imageResources, forURLScheme: "ot-image")
        configuration.setURLSchemeHandler(AppearanceResources(), forURLScheme: "ot-appearance")
        configuration.websiteDataStore = .nonPersistent()
        webView = EditorWebView(frame: .zero, configuration: configuration)
        webView.isHidden = true
        // Keep the painted loading surface inside the content area. AppKit
        // owns the separate titlebar, window buttons and unified toolbar.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = localized("document.untitled"); window.titleVisibility = .hidden
        window.minSize = NSSize(width: 640, height: 420)
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true; window.titlebarSeparatorStyle = .none
        window.backgroundColor = ThemePalette.color("bg")
        window.tabbingIdentifier = "LinoDocuments"
        window.tabbingMode = verifying ? .disallowed : .automatic
        window.center()
        super.init(window: window)
        documents = DocumentActions(bridge: bridge, window: window, verifying: verifying, initialPath: filePreview == nil ? initialPath : nil, offerRecovery: offerRecovery)
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
        webView.registerForDraggedTypes([.fileURL])
        webView.acceptsImages = { [weak self] in self?.documents.ready == true && self?.documents.busy == false && self?.documents.readOnly == false && self?.composing == false }
        webView.onImageDrop = { [weak self] paths, point in
            guard let self else { return }
            let generation = bridge.generation, owner = documents.sessionId
            Task {
                do {
                    guard try await bridge.call("prepareImageDrop", arguments: [point.x, point.y]) as? Bool == true else { return }
                    // Save before issuing asset I/O: saving waits for pending imports.
                    if !documents.hasFile, ThemePalette.preferences?.image_insertion == "copy" {
                        guard await documents.save() else { _ = try? await bridge.call("cancelImageDrop"); return }
                    }
                    guard generation == bridge.generation, owner == documents.sessionId, documents.ready, !documents.closed else { return }
                    _ = try await bridge.call("commitImageDrop", arguments: [paths])
                } catch { _ = try? await bridge.call("cancelImageDrop"); showError(userFacingError(error)) }
            }
        }
        bridge.onImageDrop = { [weak self] paths, x, y in
            guard let self, webView.acceptsImages?() == true else { return }
            webView.onImageDrop?(paths, NSPoint(x: x, y: y))
        }
        workspace = WorkspaceController(navigation: self.navigation, window: window, verifying: verifying)
        quickOpen = QuickOpenController(window: window, navigation: self.navigation)
        customization = SidebarCustomizationController(navigation: self.navigation)
        workspace.onQuickOpen = { [weak self] in self?.quickOpen.show() }
        quickOpen.currentWorkspace = { [weak self] in self?.workspace.currentRoot }
        quickOpen.onOpenFolder = { [weak self] in Task { await self?.workspace.chooseRoot() } }
        workspace.onContentSearch = { [weak self] in
            self?.setWorkspaceVisible(true); self?.workspace.showContentSearch()
        }
        workspace.onCustomize = { [weak self] in self?.showSidebarCustomization() }
        workspace.onOutlineVisibility = { [weak self] _ in self?.synchronizeOutline() }
        workspace.onHeading = { [weak self] from, token in
            guard let self else { return }
            Task {
                do { _ = try await bridge.call("navigateHeading", arguments: [from, token]); window.makeFirstResponder(webView) }
                catch { showError(userFacingError(error)) }
            }
        }
        workspace.onContinueOutline = { [weak self] in
            guard let self else { return }; Task { _ = try? await bridge.call("continueOutline") }
        }
        bridge.onOutline = { [weak self] projection in self?.workspace.applyHeadings(projection) }
        bridge.onStatistics = { [weak self] projection in self?.updateStatistics(projection) }
        workspace.onError = { [weak self] message in self?.showError(message) }
        workspace.onVisibility = { [weak self] visible in self?.setWorkspaceVisible(visible) }
        searchControls = DocumentSearchController(bridge: bridge)
        searchControls.onFocusEditor = { [weak self] in self?.window?.makeFirstResponder(self?.webView) }
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
        placeSidebar()
        sidebarObserver = self.navigation.sidebar.observe { [weak self] value in
            guard let self else { return }
            navigationSplit.setRememberedWidth(value.width)
            if desiredSidebar != value.visible { desiredSidebar = value.visible; placeSidebar() }
        }
        documents.onAvailabilityChanged = { [weak self] in
            guard let self else { return }
            viewport.setAvailable(documents.ready)
            if webView.isHidden == documents.ready { webView.isHidden = !documents.ready }
            synchronizeOutline()
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
        bridge.onContextMenu = { [weak self] context, x, y, scale in self?.showComponentMenu(context, x: x, y: y, imageScale: scale) }
        bridge.onTerminated = { [weak self] in self?.contentProcessTerminated() }
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    private func configureContent(in window: NSWindow) {
        navigationController.splitView = navigationSplit
        navigationSplit.controller = navigationController
        let content = EditorSurfaceView(editor: webView)
        _ = installWindowChrome(in: window, content: content)
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
        statisticsLabel.font = .systemFont(ofSize: 11); statisticsLabel.textColor = .secondaryLabelColor
        statisticsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [stateIcon, statusLabel, retryButton, NSView(), statisticsLabel, detailLabel])
        row.spacing = 8; row.alignment = .centerY
        let footerBackground = ThemeSurface(role: "bg")
        footerBackground.frame = footer.bounds; footerBackground.autoresizingMask = [.width, .height]
        footer.addSubview(footerBackground, positioned: .below, relativeTo: nil)
        sidebarContainer.install(workspace.view)
        navigationSplit.install(sidebar: sidebarContainer, editor: filePreview?.view ?? webView, footer: footer, pane: content, fixedBacking: filePreview == nil)
        navigationSplit.controller.view.frame = window.contentView?.bounds ?? window.frame
        window.contentViewController = navigationSplit.controller
        navigationSplit.onSidebarSafeTop = { [weak self] inset in
            guard let self, workspace.view.edgeInsets.top != inset else { return }
            workspace.view.edgeInsets.top = inset
        }
        navigationSplit.onViewportWidth = { [weak self] width in self?.viewport.resize(width) }
        navigationSplit.onTransitionCompleted = { [weak self] in
            guard let self, restoreEditorAfterSidebar, !desiredSidebar else { return }
            restoreEditorAfterSidebar = false
            self.window?.makeFirstResponder(filePreview?.focusView ?? webView)
        }
        let savedWidth = navigation.sidebar.values.width
        navigationSplit.configure(width: savedWidth >= 230 && savedWidth <= 360 ? savedWidth : 268, expanded: desiredSidebar)
        navigationSplit.onWidthChanged = { [weak self] width in
            self?.navigation.sidebar.change { $0.width = width }
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(row)
        NSLayoutConstraint.activate([
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
        externalChanges.setSaving(saving)
        let title = documents.label ?? localized("document.untitled")
        if window?.title != title { window?.title = title }
        if titleField.stringValue != title { titleField.stringValue = title }
        if window?.isDocumentEdited != dirty { window?.isDocumentEdited = dirty }
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
        if boundFileRef != documents.fileRef {
            boundFileRef = documents.fileRef; bindingTask?.cancel()
            let file = documents.fileRef, id = documents.sessionId
            bindingTask = Task { [weak self] in
                guard let self else { return }
                let path: String?
                if let id { path = try? await bridge.backend.perform { try $0.documentPath(sessionId: id) } } else { path = nil }
                guard !Task.isCancelled, boundFileRef == file else { return }
                workspace.setCurrentFile(path); quickOpen.currentFile = path; onFileBindingChanged?(path)
                if let path { await navigation.noteFile(path) }
            }
        }
        updateStatus()
    }

    private func synchronizeOutline() {
        guard documents.ready, let session = documents.sessionId else { outlineRequest = nil; return }
        let generation = bridge.generation, visible = workspace.showingOutline
        if let request = outlineRequest, request.generation == generation, request.session == session, request.visible == visible { return }
        outlineSequence &+= 1; let sequence = outlineSequence
        outlineRequest = (generation, session, visible)
        Task { [weak self] in
            guard let self, bridge.generation == generation, documents.sessionId == session else { return }
            do { _ = try await bridge.call("setOutlineVisible", arguments: [visible, String(sequence), session, generation]) }
            catch { if outlineSequence == sequence { outlineRequest = nil }; showError(userFacingError(error)) }
        }
    }
    func setWorkspaceVisible(_ value: Bool) {
        if !value, let responder = window?.firstResponder as? NSView {
            restoreEditorAfterSidebar = responder.isDescendant(of: sidebarContainer)
        } else { restoreEditorAfterSidebar = false }
        desiredSidebar = value
        navigation.sidebar.change { $0.visible = value }
        placeSidebar()
    }
    private func placeSidebar() {
        navigationSplit.show(desiredSidebar, animated: window?.isVisible == true)
    }
    private func updateChromeInsets() {
        navigationSplit.layoutPanes()
        let inset = navigationSplit.sidebarSafeTop
        if workspace.view.edgeInsets.top != inset { workspace.view.edgeInsets.top = inset }
    }
    func windowDidResize(_ notification: Notification) {
        guard !synchronizingTabLayouts else { return }
        updateChromeInsets(); quickOpen?.resize()
        // Resize each hidden backing once. Guard the entire group so AppKit's
        // resize callbacks cannot recursively resize the other tabs again.
        let controllers = (window?.tabbedWindows ?? []).compactMap { $0.windowController as? EditorWindowController }
        for controller in controllers { controller.synchronizingTabLayouts = true }
        defer { for controller in controllers { controller.synchronizingTabLayouts = false } }
        for controller in controllers where controller !== self {
            guard let tab = controller.window else { continue }
            if let frame = window?.frame, tab.frame.size != frame.size { tab.setFrame(frame, display: false) }
            tab.contentView?.layoutSubtreeIfNeeded(); controller.updateChromeInsets()
        }
    }
    func showSidebarCustomization() { setWorkspaceVisible(true); customization.show(relativeTo: workspace.view.arrangedSubviews.first ?? workspace.view) }
    @objc func toggleWorkspace() { setWorkspaceVisible(!desiredSidebar) }
    private func updateStatistics(_ projection: [String: Any]) {
        guard let counts = projection["counts"] as? [String: Any], let words = counts["words"] as? Int else { return }
        statisticsLabel.isHidden = projection["visible"] as? Bool == false
        statisticsLabel.stringValue = localized(projection["selection"] as? Bool == true ? "navigation.selectionWords" : "navigation.words", words)
        statisticsLabel.toolTip = localized("navigation.countDetails", words, counts["characters"] as? Int ?? 0, counts["lines"] as? Int ?? 0)
    }
    func writingMenuState(_ command: String) -> NSControl.StateValue {
        let key = ["toggle-outline": "outline", "toggle-statistics": "statistics", "focus-mode": "focus", "typewriter-mode": "typewriter", "code-wrap": "codeWrap", "code-line-numbers": "codeNumbers"][command]
        return key.flatMap { writingStatus[$0] as? Bool } == true ? .on : .off
    }
    func showError(_ message: String) { errorMessage = message; noticeKey = nil; updateStatus() }
    private func showNotice(_ key: String) { noticeKey = key; errorMessage = nil; updateStatus() }

    func relocalize() {
        workspace.relocalize(); quickOpen.relocalize(); filePreview?.relocalize()
        if let root = window?.contentView { ThemePalette.refresh(root) }
        webView.setAccessibilityLabel(localized("editor.accessibility"))
        retryButton.setAccessibilityLabel(localized("status.retryAccessibility"))
        for item in window?.toolbar?.items ?? [] { localizeToolbarItem(item) }
        if let documentStatus { updateDocument(documentStatus) }
        else if isPreviewing { statusLabel.stringValue = localized("preview.readOnly"); titleField.toolTip = localized("preview.readOnly") }
        else { documentMessage = localized("status.loading"); updateStatus() }
    }
    private func updateStatus() {
        let zoom = (writingStatus["zoom"] as? Double) ?? 1
        detailLabel.stringValue = zoom == 1 ? "" : "\(Int((zoom * 100).rounded()))%"
        let error = (persistenceError ?? errorMessage).map { localized("status.errorDetail", $0) }
        let notice = noticeKey.map { localized($0) }
        let external = externalState == "changed" ? localized("status.externalChanged") : externalState == "deleted" ? localized("status.externalDeleted") : ""
        let quietStatus: String
        if let error { quietStatus = error }
        else if let notice { quietStatus = notice }
        else if !external.isEmpty { quietStatus = external }
        else if !documents.ready { quietStatus = documentMessage }
        else if documents.readOnly { quietStatus = localized("status.readOnly") }
        else if documentStatus?["saving"] as? Bool == true { quietStatus = localized("navigation.saving") }
        else if documentStatus?["dirty"] as? Bool == true { quietStatus = localized("navigation.unsaved") }
        else { quietStatus = localized(documents.hasFile ? "status.saved" : "document.untitled") }
        statusLabel.stringValue = quietStatus
        statusLabel.toolTip = error ?? (documentMessage + (composing ? " · " + localized("status.composing") : ""))
        statusLabel.textColor = error == nil ? .secondaryLabelColor : .systemOrange
        stateIcon.image = NSImage(systemSymbolName: error == nil ? documentStatus?["dirty"] as? Bool == true ? "circle.fill" : documents.hasFile ? "checkmark" : "doc" : "exclamationmark.triangle", accessibilityDescription: error == nil ? localized("status.documentAccessibility") : localized("status.errorAccessibility"))
        stateIcon.contentTintColor = error == nil ? .secondaryLabelColor : .systemOrange
        retryButton.isHidden = persistenceError == nil && documents.ready
        retryButton.title = documents.ready ? localized("status.retry") : localized("status.reconnect")
    }

    func showFilePreview() {
        guard let filePreview else { return }
        window?.title = filePreview.url.lastPathComponent
        titleField.stringValue = filePreview.url.lastPathComponent
        titleField.toolTip = localized("preview.readOnly")
        workspace.setCurrentFile(filePreview.url.path); quickOpen.currentFile = filePreview.url.path
        onFileBindingChanged?(filePreview.url.path)
        statisticsLabel.isHidden = true; statusLabel.stringValue = localized("preview.readOnly")
        window?.contentView?.layoutSubtreeIfNeeded(); updateChromeInsets(); filePreview.prepare()
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
    }
    func loadEditor() throws {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Editor", isDirectory: true) else {
            throw NSError(domain: "Lino", code: 1, userInfo: [NSLocalizedDescriptionKey: localized("error.missingResources")])
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        updateChromeInsets()
        viewport.setAvailable(false)
        bridge.beginNavigation(viewportWidth: navigationSplit.viewportWidth)
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
        do { try loadEditor() } catch { showError(userFacingError(error)) }
    }

    func reconnect() {
        guard !documents.ready && !documents.busy else { return }
        automaticReconnectUsed = false
        do { try loadEditor() } catch { showError(userFacingError(error)) }
    }

    func detach() {
        if let sidebarObserver { navigation.sidebar.removeObserver(sidebarObserver); self.sidebarObserver = nil }
        navigationSplit.detach()
        viewport.detach()
        filePreview?.detach()
        exports.detach()
        externalChanges.detach()
        imageResources.cancelAll(); bridge.onAssetOperation = nil
        bridge.onContextMenu = nil; bridge.onImageDrop = nil
        bindingTask?.cancel(); quickOpen.detach()
        workspace.detach()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "editor")
        webView.navigationDelegate = nil; webView.stopLoading()
    }
    func windowWillClose(_ notification: Notification) { onClosed?() }
    func windowDidBecomeKey(_ notification: Notification) { onActivated?(); updateChromeInsets(); externalChanges?.check(); if let path = workspace.currentFile { Task { await navigation.noteFile(path) } } }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let filePreview { onWillClose?(filePreview.url.path); return true }
        if documents.closed { return true }
        Task { [weak self] in
            guard let self else { return }
            let path: String?
            if let id = documents.sessionId { path = try? await bridge.backend.perform { try $0.documentPath(sessionId: id) } } else { path = nil }
            if await documents.close() { onWillClose?(path); sender.performClose(nil) }
        }
        return false
    }
    var isActiveDocument: Bool { window != nil && (NSApp.keyWindow === window || quickOpen?.owns(NSApp.keyWindow) == true) && window?.attachedSheet == nil }
    var editorHasKeyboardFocus: Bool {
        guard isActiveDocument, let responder = window?.firstResponder as? NSView else { return false }
        return responder === webView || responder.isDescendant(of: webView)
    }
    func allowsCommand(_ command: String, fromToolbar: Bool = false) -> Bool {
        guard !isPreviewing, documents.ready, isActiveDocument else { return false }
        if ["visual", "source", "toggle-source", "find", "replace", "find-next", "find-previous", "toggle-find", "close-find", "goto-line", "toggle-outline", "toggle-statistics", "focus-mode", "typewriter-mode", "zoom-in", "zoom-out", "zoom-reset"].contains(command) { return true }
        if documents.readOnly && !["code-copy", "code-line-numbers", "code-wrap", "image-smaller", "image-larger", "image-reset-size", "image-reveal", "image-copy", "open-link", "copy-link", "goto-footnote", "preview-copy-source", "preview-copy-mathml", "preview-copy-svg", "preview-save-svg", "preview-refresh", "preview-cancel"].contains(command) { return false }
        if command != "code-block" && command.hasPrefix("code-") {
            if !inCodeBlock || (command == "code-language" && !codeFenced) { return false }
            if ["code-indent", "code-outdent"].contains(command) && !codeCanIndent { return false }
        }
        return !composing && (fromToolbar || editorHasKeyboardFocus)
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { isActiveDocument && (item.itemIdentifier == .editorWorkspace || documents.ready && !isPreviewing) }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let command = item.representedObject as? String else { return documents.ready && isActiveDocument }
        item.state = writingMenuState(command)
        return allowsCommand(command, fromToolbar: true)
    }
    func performEditorCommand(_ command: String) {
        if command == "toggle-outline" {
            let show = !workspace.showingOutline || !workspaceVisible
            if show { workspace.setOutline(true) }; setWorkspaceVisible(show)
        } else if command == "find" || command == "replace" { searchControls.open(replacing: command == "replace") }
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
