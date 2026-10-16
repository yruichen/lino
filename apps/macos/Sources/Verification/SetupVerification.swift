import AppKit

/// Own windows and synthetic documents only; never installs or changes file associations.
@MainActor
func verifySetupFlow() async throws -> [String] {
    var passed: [String] = []
    func check(_ name: String, _ value: Bool) throws {
        guard value else { throw NSError(domain: "SetupVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
        passed.append(name)
    }
    func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    func button(_ setup: SetupWindowController, _ key: String) throws -> NSButton {
        guard let root = setup.window?.contentView, let button = views(root).compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == key }) else { throw CocoaError(.coderInvalidValue) }
        return button
    }
    func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard condition() else { throw NSError(domain: "SetupVerification", code: 2, userInfo: [NSLocalizedDescriptionKey: "Welcome transition did not settle"]) }
    }
    let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
    try check("installation-recognizes-applications-and-download-locations", InstallationServices.isInstalled(URL(fileURLWithPath: "/Applications/Lino.app"), home: home) && InstallationServices.isInstalled(home.appendingPathComponent("Applications/Lino.app"), home: home) && !InstallationServices.isInstalled(URL(fileURLWithPath: "/Volumes/Lino/Lino.app"), home: home) && !InstallationServices.isInstalled(home.appendingPathComponent("Downloads/Lino.app"), home: home))
    let types = Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
    try check("installation-retains-optional-markdown-association", types.contains { ($0["LSItemContentTypes"] as? [String])?.contains("net.daringfireball.markdown") == true && $0["LSHandlerRank"] as? String == "Alternate" && $0["CFBundleTypeRole"] as? String == "Editor" })
    let brewHome = FileManager.default.temporaryDirectory.appendingPathComponent("lino-brew-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: brewHome) }
    let cask = brewHome.appendingPathComponent("Caskroom/lino/Lino.app")
    try FileManager.default.createDirectory(at: cask, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: brewHome.appendingPathComponent("Applications"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: brewHome.appendingPathComponent("Applications/Lino.app"), withDestinationURL: cask)
    try check("homebrew-linked-app-is-already-installed", InstallationServices.isInstalled(cask, home: brewHome))
    let originalLanguage = LanguagePreferences.shared.preference
    defer { LanguagePreferences.shared.select(originalLanguage) }
    let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/validation")
    for language in [InterfaceLanguage.english, .simplifiedChinese] {
        LanguagePreferences.shared.select(language)
        for dark in [false, true] {
            for mode in [SetupWindowController.Mode.welcome, .install] {
                let setup = SetupWindowController(mode: mode, openFile: {})
                defer { setup.close() }
                guard let window = setup.window, let root = window.contentView else { throw CocoaError(.coderInvalidValue) }
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                setup.showWindow(nil); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                try await Task.sleep(for: .milliseconds(80)); root.layoutSubtreeIfNeeded()
                let buttons = views(root).compactMap { $0 as? NSButton }.filter { !$0.isHidden }
                try check("\(language.rawValue)-\(dark ? "dark" : "light")-\(mode)-two-clear-actions", buttons.count == 2 && !views(root).contains { $0 is NSScrollView } && buttons.allSatisfy { root.bounds.contains(root.convert($0.bounds, from: $0)) })
                guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { throw CocoaError(.coderInvalidValue) }
                guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.coderInvalidValue) }
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill(); root.bounds.fill()
                    root.displayIgnoringOpacity(root.bounds, in: context)
                }
                NSGraphicsContext.restoreGraphicsState()
                try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("setup-\(mode)-\(language.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
    }
    LanguagePreferences.shared.select(.english)
    var opens = 0, closes = 0
    let setup = SetupWindowController(openFile: { opens += 1 }, finish: { closes += 1 })
    setup.window?.alphaValue = 0; setup.showWindow(nil)
    try button(setup, "setup.openFile").performClick(nil)
    try check("cancelled-file-choice-retains-welcome", opens == 1 && setup.window?.isVisible == true && closes == 0)
    setup.documentPresented()
    try check("presented-document-dismisses-welcome-without-creating-another", setup.window?.isVisible == false && closes == 0)
    var attempts = 0, trials = 0
    let installer = SetupWindowController(mode: .install, openFile: {}, install: {
        attempts += 1
        try await Task.sleep(for: .milliseconds(100))
        if attempts == 1 { throw ApplicationInstallationError.applicationRunning }
    }, tryWithoutInstalling: { trials += 1 })
    installer.window?.alphaValue = 0; installer.showWindow(nil)
    let installButton = try button(installer, "setup.installAndOpen")
    installButton.performClick(nil)
    try check("installation-prevents-double-submission-and-close-while-copying", installer.installing && !installButton.isEnabled && !installer.windowShouldClose(installer.window!))
    try await wait { !installer.installing }
    try check("installation-failure-stays-visible-and-offers-retry", installer.window?.isVisible == true && installButton.isEnabled && installButton.title == localized("setup.retryInstall"))
    installButton.performClick(nil)
    try await wait { !installer.installing }
    try check("installation-retry-completes-and-closes", attempts == 2 && installer.window?.isVisible == false && trials == 0)
    let trial = SetupWindowController(mode: .install, openFile: {}, tryWithoutInstalling: { trials += 1 })
    trial.window?.alphaValue = 0; trial.showWindow(nil)
    try button(trial, "setup.tryFirst").performClick(nil)
    try check("try-without-installing-enters-writing", trials == 1 && trial.window?.isVisible == false)

    // Reproduce the actual asynchronous WebView initialization that covered the old guide.
    let documents = DocumentWindows(verifying: true)
    try await documents.navigation.configure(verifying: true)
    var ready = false
    let welcome = SetupWindowController(newDocument: { documents.create() }, openFile: {})
    welcome.window?.alphaValue = 0; welcome.showWindow(nil)
    documents.onDocumentPresented = {
        ready = documents.controllers.first?.window?.isVisible == true
        welcome.documentPresented()
    }
    defer { welcome.close(); for document in documents.controllers { document.window?.close() }; documents.detach() }
    try check("first-use-has-no-editor-behind-welcome", documents.controllers.isEmpty && welcome.window?.isVisible == true)
    guard let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: welcome.window!.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { throw CocoaError(.coderInvalidValue) }
    try check("return-key-starts-a-document", welcome.window!.performKeyEquivalent(with: enter))
    try check("welcome-remains-until-editor-is-ready", !ready && welcome.window?.isVisible == true)
    try await wait { ready }
    try check("editor-readiness-hands-off-window-once", documents.controllers.count == 1 && welcome.window?.isVisible == false && documents.controllers.first?.documents.ready == true)
    try check("editor-receives-key-window-after-welcome", NSApp.keyWindow === documents.controllers.first?.window)
    if let document = documents.controllers.first { _ = await document.documents.close(); document.documents.cleanupVerificationFiles() }
    return passed
}
