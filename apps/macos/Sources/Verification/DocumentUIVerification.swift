import AppKit
import WebKit

/// Real document windows, bundled editor resources, and temporary files only.
@MainActor
func verifyDocumentUI() async throws -> [String] {
    let windows = DocumentWindows(verifying: true)
    try await windows.navigation.configure(verifying: true)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lino-document-ui-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func cleanup() async {
        for document in Array(windows.controllers) {
            if let sheet = document.window?.attachedSheet { document.window?.endSheet(sheet, returnCode: .cancel) }
            let state = document.documents.ready ? try? await document.bridge.call("snapshot") as? [String: Any] : nil
            if document.documents.ready, !document.documents.busy, state?["dirty"] as? Bool != true {
                _ = await document.documents.close()
            }
            if !document.documents.closed, let session = document.documents.sessionId {
                try? await windows.backend.perform { try $0.abandonDocument(sessionId: session) }
            }
            document.documents.cleanupVerificationFiles()
            // close() keeps the delegate: onClosed releases the view, path and
            // window registry even on a failed fixture's abandonment path.
            document.window?.close()
        }
        windows.detach()
        try? FileManager.default.removeItem(at: directory)
    }
    func exercise() async throws -> [String] {
        var passed: [String] = [], failed: [String] = []
        func check(_ name: String, _ value: Bool) {
            (value ? passed.append(name) : failed.append(name))
        }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            guard condition() else { throw NSError(domain: "DocumentUIVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: "Document did not become ready"]) }
        }
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items + menu.items.flatMap { $0.submenu.map(items) ?? [] } }
        if let menu = NSApp.mainMenu {
            // AppKit can append its own nested menus with an internal title
            // different from the displayed item. Verify our visible entries.
            let expected = ["Lino", localized("menu.file"), localized("menu.edit"), localized("format.title"), localized("menu.view"), localized("workspace.windows")]
            let top = menu.items.map(\.title)
            let file = menu.items.first { $0.title == localized("menu.file") }?.submenu
            let view = menu.items.first { $0.title == localized("menu.view") }?.submenu
            let recent = file?.items.first { $0.submenu?.title == localized("workspace.recentFiles") }
            let sidebar = view?.items.first { $0.submenu?.title == localized("navigation.sidebar") }
            check("native-submenu-entries-have-real-localized-titles", expected.allSatisfy { top.contains($0) } && !top.contains("NSMenuItem") && recent?.title == localized("workspace.recentFiles") && sidebar?.title == localized("navigation.sidebar"))
            check("native-file-menu-offers-an-explicit-new-window", items(menu).contains { $0.action == NSSelectorFromString("newWindow") && $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == [.command, .option] })
        }
        let dock = NSApp.delegate?.applicationDockMenu?(NSApp)
        check("dock-offers-new-document-new-window-and-open", ["newDocument", "newWindow", "openDocument"].allSatisfy { selector in dock?.items.contains { $0.action == NSSelectorFromString(selector) } == true })
        // Sample the document before its own theme script runs. A user-selected
        // appearance must already match the native canvas at document start.
        let bootstrap = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        bootstrap.appearance = NSAppearance(named: .darkAqua)
        let bootstrapBridge = EditorBridge(backend: windows.backend); bootstrapBridge.webView = bootstrap
        bootstrapBridge.beginNavigation(viewportWidth: 320)
        bootstrap.loadHTMLString("<html><body>Bootstrap</body></html>", baseURL: nil)
        try await wait { !bootstrap.isLoading && bootstrap.url != nil }
        let firstBackground = try await bootstrap.callAsyncJavaScript("return getComputedStyle(document.documentElement).backgroundColor;", arguments: [:], in: nil, contentWorld: .page) as? String
        let expectedColor = ThemePalette.current.dark.colors["bg"].map(ThemePalette.hex)?.usingColorSpace(.sRGB)
        let expectedBackground = expectedColor.map { "rgb(\(Int(($0.redComponent * 255).rounded())), \(Int(($0.greenComponent * 255).rounded())), \(Int(($0.blueComponent * 255).rounded())))" }
        check("document-start-uses-confirmed-theme-before-editor-bootstrap", firstBackground == expectedBackground)
        bootstrap.stopLoading()
        let one = directory.appendingPathComponent("One.md"), two = directory.appendingPathComponent("Two.md")
        try Data("# One\n\nKeep this document's history.\n".utf8).write(to: one)
        try Data("# Two\n\nA different document.\n".utf8).write(to: two)
        let initial = windows.controllers.count
        let source = windows.create(path: one.path)
        try await wait { source.documents.ready }
        guard let window = source.window else { throw ImageDataError.invalid }
        window.setContentSize(NSSize(width: 760, height: 560)); window.contentView?.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil)
        let second = windows.create(path: two.path)
        var initialWidth: CGFloat?
        let previous = second.bridge.onDocument
        second.bridge.onDocument = { [weak second] status in
            if initialWidth == nil { initialWidth = second?.window?.frame.width }
            previous?(status)
        }
        try await wait { second.documents.ready && second.window?.isVisible == true }
        check("new-document-initializes-at-its-origin-window-size", initialWidth == window.frame.width)
        check("ordinary-open-joins-the-current-native-tab-group", window.tabbedWindows?.contains { $0 === second.window } == true)
        let third = windows.create()
        try await wait { third.documents.ready && third.window?.isVisible == true }
        check("new-untitled-document-joins-the-current-native-tab-group", second.window?.tabbedWindows?.contains { $0 === third.window } == true)
        var appearance = try PreferencesCoordinator.decode(await windows.backend.perform { try $0.preferences() })
        appearance.values.theme = "dark"
        for document in [source, second, third] {
            document.window?.appearance = NSAppearance(named: .darkAqua)
            try await document.documents.applyPreferences(appearance.json())
        }
        let count = windows.controllers.count
        await windows.open(path: one.path)
        check("opening-an-existing-document-selects-it-without-another-session", windows.controllers.count == count && window.tabGroup?.selectedWindow === window)
        for selected in [second, source, third, source] {
            selected.window?.tabGroup?.selectedWindow = selected.window
            selected.window?.makeKeyAndOrderFront(nil)
            let state = try await selected.bridge.call("snapshot") as? [String: Any] ?? [:]
            let expected = selected === source ? "# One\n\nKeep this document's history.\n" : selected === second ? "# Two\n\nA different document.\n" : ""
            check("tab-switch-retains-document-\(selected === source ? "one" : selected === second ? "two" : "untitled")", state["text"] as? String == expected && !selected.webView.isHidden)
            let theme = try await selected.webView.callAsyncJavaScript("return {background:getComputedStyle(document.documentElement).backgroundColor, width:document.querySelector('.cm-editor').getBoundingClientRect().width};", arguments: [:], in: nil, contentWorld: .page) as? [String: Any] ?? [:]
            let native = selected.webView.underPageBackgroundColor.usingColorSpace(.sRGB)
            let correctNative = native.map { color in
                guard let expectedColor else { return false }
                return abs(color.redComponent - expectedColor.redComponent) < 0.005 && abs(color.greenComponent - expectedColor.greenComponent) < 0.005 && abs(color.blueComponent - expectedColor.blueComponent) < 0.005
            } ?? false
            check("tab-theme-and-native-backing-agree-after-switch", theme["background"] as? String == expectedBackground && correctNative && abs((theme["width"] as? Double ?? 0) - selected.navigationSplit.viewportWidth) < 1)
        }
        try await captureFixtureWindow(source, destination: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/validation/document-ui.png"))
        let independent = windows.create(newWindow: true)
        try await wait { independent.documents.ready && independent.window?.isVisible == true }
        check("explicit-new-window-stays-outside-existing-tab-groups", independent.window !== window && window.tabbedWindows?.contains { $0 === independent.window } != true)
        let inIndependent = windows.create()
        try await wait { inIndependent.documents.ready && inIndependent.window?.isVisible == true }
        check("ordinary-new-document-follows-the-last-used-independent-window", independent.window?.tabbedWindows?.contains { $0 === inIndependent.window } == true && window.tabbedWindows?.contains { $0 === inIndependent.window } != true)
        let dockWithDocuments = documentDockMenu(documents: windows.controllers, active: source, recentFiles: [one, two], target: NSApp.delegate!)
        let documentItems = dockWithDocuments.items.filter { $0.action == NSSelectorFromString("activateDocument:") }
        check("dock-lists-live-documents-and-marks-the-active-document", documentItems.count == windows.controllers.count - initial && documentItems.first { $0.representedObject as? EditorWindowController === source }?.state == .on)
        let recentEntries = dockWithDocuments.items.first { $0.submenu != nil }?.submenu?.items ?? []
        check("dock-recent-items-preserve-their-exact-file-destinations", recentEntries.map { $0.representedObject as? String } == [one.path, two.path])
        // Exercise the real alert, editor transport and disk commit together.
        // Cancellation must keep input editable and permit a later close/save.
        func button(_ title: String) -> NSButton? {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            return window.attachedSheet?.contentView.flatMap { descendants($0).first { ($0 as? NSButton)?.title == title } as? NSButton }
        }
        window.tabGroup?.selectedWindow = window; window.makeKeyAndOrderFront(nil)
        _ = try await source.bridge.call("command", arguments: ["horizontal-rule"])
        let beforeSave = try await source.bridge.call("snapshot") as? [String: Any] ?? [:]
        let edited = beforeSave["text"] as? String ?? ""
        check("native-conflict-fixture-has-pending-local-edits", beforeSave["dirty"] as? Bool == true)
        try Data("External change\n".utf8).write(to: one, options: .atomic)
        let cancelledSave = Task { await source.documents.save() }
        try await wait { button(localized("dialog.keepEditing")) != nil }
        button(localized("dialog.keepEditing"))?.performClick(nil)
        let kept = await cancelledSave.value
        let afterCancel = try await source.bridge.call("snapshot") as? [String: Any] ?? [:]
        let diskAfterCancel = try String(contentsOf: one, encoding: .utf8)
        check("native-conflict-cancel-keeps-local-input-and-external-file", !kept && !source.documents.busy && afterCancel["dirty"] as? Bool == true && afterCancel["text"] as? String == edited && diskAfterCancel == "External change\n")
        let save = Task { await source.documents.save() }
        try await wait { button(localized("dialog.overwriteFile")) != nil }
        button(localized("dialog.overwriteFile"))?.performClick(nil)
        let saved = await save.value
        let diskAfterSave = try String(contentsOf: one, encoding: .utf8)
        check("native-conflict-explicit-overwrite-saves-the-editor-snapshot", saved && diskAfterSave == edited)
        _ = try await source.bridge.call("command", arguments: ["horizontal-rule"])
        let closingText = (try await source.bridge.call("snapshot") as? [String: Any])?["text"] as? String ?? ""
        try Data("Another external change\n".utf8).write(to: one, options: .atomic)
        let close = Task { await source.documents.close() }
        try await wait { button(localized("dialog.saveClose")) != nil }
        button(localized("dialog.saveClose"))?.performClick(nil)
        try await wait { button(localized("dialog.overwriteFile")) != nil }
        button(localized("dialog.overwriteFile"))?.performClick(nil)
        let closed = await close.value
        let diskAfterClose = try String(contentsOf: one, encoding: .utf8)
        check("native-save-and-close-resolves-the-same-conflict-without-trapping-input", closed && source.documents.closed && diskAfterClose == closingText)
        window.close()
        guard failed.isEmpty else { throw NSError(domain: "DocumentUIVerification", code: 2, userInfo: [NSLocalizedDescriptionKey: failed.joined(separator: ", ")]) }
        return passed
    }
    do {
        var result = try await exercise()
        await cleanup()
        guard windows.controllers.isEmpty else { throw NSError(domain: "DocumentUIVerification", code: 3, userInfo: [NSLocalizedDescriptionKey: "Fixture cleanup retained document windows"]) }
        result.append("document-fixture-closes-sessions-and-releases-window-registry")
        return result
    } catch {
        await cleanup()
        throw error
    }
}
