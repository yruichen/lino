import AppKit
import WebKit

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation, NSMenuItemValidation {
    let bridge = EditorBridge()
    let webView: WKWebView
    let modeControl = NSSegmentedControl(labels: [localized("menu.edit"), localized("editor.source")], trackingMode: .selectOne, target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: localized("status.loading"))
    private let stateIcon = NSImageView()
    private let detailLabel = NSTextField(labelWithString: localized("status.markdownEncoding"))
    private let retryButton = NSButton(title: localized("status.retry"), target: nil, action: nil)
    private(set) var documents: DocumentActions!
    private var documentMessage = localized("status.loading")
    private var composing = false
    private var documentStatus: [String: Any]?
    private var noticeKey: String?
    private var errorMessage: String?
    private var persistenceError: String?
    private var automaticReconnectUsed = false
    var onClosed: (() -> Void)?
    private(set) var canUndo = false
    private(set) var canRedo = false

    init(verifying: Bool = false) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isHidden = true
        // Keep the painted loading surface inside the content area. AppKit
        // owns the separate titlebar, window buttons and unified toolbar.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = localized("document.untitled"); window.subtitle = "Open Typora"
        window.minSize = NSSize(width: 640, height: 420)
        window.toolbarStyle = .unified
        window.center()
        super.init(window: window)
        documents = DocumentActions(bridge: bridge, window: window, verifying: verifying)
        window.delegate = self
        bridge.webView = webView
        configuration.userContentController.add(bridge, name: "editor")
        webView.navigationDelegate = bridge
        webView.setAccessibilityLabel(localized("editor.accessibility"))
        modeControl.selectedSegment = 0
        modeControl.target = self; modeControl.action = #selector(modeChanged)
        modeControl.setAccessibilityLabel(localized("menu.visual"))
        modeControl.toolTip = localized("editor.modeTip")
        modeControl.isEnabled = false
        let toolbar = NSToolbar(identifier: "document")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        configureContent(in: window)
        documents.onAvailabilityChanged = { [weak self] in
            guard let self else { return }
            modeControl.isEnabled = documents.ready
            webView.isHidden = !documents.ready
            window.toolbar?.validateVisibleItems()
            updateStatus()
        }
        documents.onOperationStarted = { [weak self] in self?.errorMessage = nil; self?.noticeKey = nil; self?.updateStatus() }
        documents.onReattached = { [weak self] in self?.showNotice("status.reconnected") }
        bridge.onStatus = { [weak self] status in
            guard let self else { return }
            canUndo = status["canUndo"] as? Bool == true && status["composing"] as? Bool != true
            canRedo = status["canRedo"] as? Bool == true && status["composing"] as? Bool != true
            modeControl.selectedSegment = status["mode"] as? String == "source" ? 1 : 0
            composing = status["composing"] as? Bool == true
            updateStatus()
        }
        bridge.onDocument = { [weak self] status in self?.updateDocument(status) }
        bridge.onError = { [weak self] message in self?.showError(message) }
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
        for view in [webView, footer, row] { view.translatesAutoresizingMaskIntoConstraints = false }
        content.addSubview(webView); content.addSubview(footer); footer.addSubview(row)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.topAnchor.constraint(equalTo: content.topAnchor),
            webView.bottomAnchor.constraint(equalTo: footer.topAnchor),
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
        documentStatus = status
        let dirty = status["dirty"] as? Bool == true
        let saving = status["saving"] as? Bool == true
        documents.hasFile = status["hasFile"] as? Bool == true
        documents.label = status["label"] as? String
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
        detailLabel.stringValue = status["autosave"] as? Bool == true ? localized("status.autosaveEncoding") : localized("status.markdownEncoding")
        updateStatus()
    }

    func showError(_ message: String) { errorMessage = message; noticeKey = nil; updateStatus() }
    private func showNotice(_ key: String) { noticeKey = key; errorMessage = nil; updateStatus() }

    func relocalize() {
        modeControl.setLabel(localized("editor.visual"), forSegment: 0)
        modeControl.setLabel(localized("editor.source"), forSegment: 1)
        modeControl.setAccessibilityLabel(localized("editor.mode"))
        modeControl.toolTip = localized("editor.modeTip")
        webView.setAccessibilityLabel(localized("editor.accessibility"))
        retryButton.setAccessibilityLabel(localized("status.retryAccessibility"))
        for item in window?.toolbar?.items ?? [] { localizeToolbarItem(item) }
        if let documentStatus { updateDocument(documentStatus) }
        else { documentMessage = localized("status.loading"); updateStatus() }
    }
    private func updateStatus() {
        let error = (persistenceError ?? errorMessage).map { localized("status.errorDetail", $0) } ?? noticeKey.map { localized($0) }
        statusLabel.stringValue = error ?? [documentMessage, composing ? localized("status.composing") : ""].filter { !$0.isEmpty }.joined(separator: " · ")
        statusLabel.toolTip = statusLabel.stringValue
        statusLabel.textColor = error == nil ? .secondaryLabelColor : .systemOrange
        stateIcon.image = NSImage(systemSymbolName: error == nil ? "checkmark.circle" : "exclamationmark.triangle", accessibilityDescription: error == nil ? localized("status.documentAccessibility") : localized("status.errorAccessibility"))
        stateIcon.contentTintColor = error == nil ? .secondaryLabelColor : .systemOrange
        retryButton.isHidden = persistenceError == nil && documents.ready
        retryButton.title = documents.ready ? localized("status.retry") : localized("status.reconnect")
    }

    func loadEditor() throws {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Editor", isDirectory: true) else {
            throw NSError(domain: "OpenTypora", code: 1, userInfo: [NSLocalizedDescriptionKey: localized("error.missingResources")])
        }
        bridge.beginNavigation()
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
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "editor")
        webView.navigationDelegate = nil; webView.stopLoading()
    }
    func windowWillClose(_ notification: Notification) { onClosed?() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if documents.closed { return true }
        Task { [weak self] in
            guard let self else { return }
            if await documents.close() { sender.performClose(nil) }
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
        if ["visual", "source", "toggle-source", "find", "replace", "find-next", "find-previous", "goto-line"].contains(command) { return true }
        return !composing && (fromToolbar || editorHasKeyboardFocus)
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { documents.ready && isActiveDocument }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let command = item.representedObject as? String else { return documents.ready && isActiveDocument }
        return allowsCommand(command, fromToolbar: true)
    }
    @objc func modeChanged() {
        let command = modeControl.selectedSegment == 0 ? "visual" : "source"
        if allowsCommand(command, fromToolbar: true) { bridge.command(command) }
    }
    @objc func find() { if allowsCommand("find", fromToolbar: true) { bridge.command("find") } }
    @objc func formatAction(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? String, allowsCommand(command, fromToolbar: true) { bridge.command(command) }
    }
    @objc private func retry() {
        if documents.ready { Task { await documents.retryPersistence() } }
        else { reconnect() }
    }
}
