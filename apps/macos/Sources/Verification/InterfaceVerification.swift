import AppKit
import ImageIO
import UniformTypeIdentifiers

private actor ReleaseAttemptFixture {
    private(set) var attempts = 0
    func fetch() throws -> String {
        attempts += 1
        if attempts == 1 { throw URLError(.notConnectedToInternet) }
        return "[{\"tag_name\":\"v9.0.0\",\"prerelease\":true,\"draft\":false}]"
    }
}

@MainActor
func verifyInterface(_ controller: EditorWindowController) async throws -> [String] {
    var passed: [String] = []
    func check(_ name: String, _ condition: Bool) throws {
        guard condition else { throw NSError(domain: "InterfaceVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
        passed.append(name)
    }
    func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try check("interface-request-settles", condition())
    }
    func capture(_ view: NSView, _ name: String) throws {
        view.layoutSubtreeIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/validation/" + name + ".png")) }
        }
    }
    let bundle = Bundle.main.infoDictionary ?? [:]
    let types = bundle["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
    try check("bundle-declares-markdown-as-editor-without-taking-default", types.contains { ($0["LSItemContentTypes"] as? [String])?.contains("net.daringfireball.markdown") == true && $0["CFBundleTypeRole"] as? String == "Editor" && $0["LSHandlerRank"] as? String == "Alternate" })
    let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
    try check("installation-recognizes-system-and-user-applications-only", InstallationServices.isInstalled(URL(fileURLWithPath: "/Applications/Lino.app"), home: home) && InstallationServices.isInstalled(home.appendingPathComponent("Applications/Lino.app"), home: home) && !InstallationServices.isInstalled(URL(fileURLWithPath: "/Volumes/Lino/Lino.app"), home: home) && !InstallationServices.isInstalled(home.appendingPathComponent("Downloads/Lino.app"), home: home))
    var openedFixture = false
    let setup = SetupWindowController(installation: InstallationServices(applicationURL: home.appendingPathComponent("Downloads/Lino.app")), openFile: { openedFixture = true }, openFolder: {})
    setup.showWindow(nil); setup.window?.alphaValue = 0
    if let root = setup.window?.contentView {
        root.layoutSubtreeIfNeeded()
        let controls = views(root).compactMap { $0 as? NSButton }
        try check("welcome-does-not-change-associations-before-installation", controls.first { $0.identifier?.rawValue == "setup.makeDefault" }?.isEnabled == false)
        try check("welcome-explains-permissions-and-reaches-real-file-entry", controls.contains { $0.identifier?.rawValue == "setup.permissions" })
        try capture(root, "installation-guide")
        controls.first { $0.identifier?.rawValue == "setup.openFile" }?.performClick(nil)
        try check("welcome-open-file-routes-action-and-closes-guide", openedFixture && setup.window?.isVisible == false)
    } else { try check("welcome-has-content", false) }
    setup.close()
    if let menu = NSApp.mainMenu {
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items + menu.items.flatMap { $0.submenu.map(items) ?? [] } }
        let formats = items(menu).filter { $0.representedObject is String }
        try check("all-markdown-shortcuts-are-discoverable-in-native-menus", EditorShortcuts.bindings.allSatisfy { binding in formats.contains { $0.representedObject as? String == binding.command && $0.keyEquivalent == binding.key } })
        controller.window?.makeKeyAndOrderFront(nil); controller.window?.makeFirstResponder(controller.webView)
        _ = try await controller.bridge.call("focusEditor")
        try await wait { controller.isActiveDocument }
        let original = try await controller.bridge.call("snapshot") as? [String: Any] ?? [:]
        func press(_ key: String, _ code: UInt16) throws {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code) else { throw CocoaError(.coderInvalidValue) }
            try check("native-markdown-shortcut-dispatched-" + key, menu.performKeyEquivalent(with: event))
        }
        try press("1", 18); try await Task.sleep(for: .milliseconds(50))
        let heading = try await controller.bridge.call("snapshot") as? [String: Any] ?? [:]
        try check("native-cmd-1-sets-heading-without-changing-mode", (heading["text"] as? String)?.hasPrefix("# ") == true && heading["mode"] as? String == original["mode"] as? String)
        try press("0", 29); try await Task.sleep(for: .milliseconds(50))
        let paragraph = try await controller.bridge.call("snapshot") as? [String: Any] ?? [:]
        try check("native-cmd-0-restores-paragraph", paragraph["text"] as? String == original["text"] as? String)
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lino-interface-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = CGContext(data: nil, width: 180, height: 80, bitsPerComponent: 8, bytesPerRow: 720, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.systemBlue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 180, height: 80))
    let imageURL = directory.appendingPathComponent("Small.png")
    let output = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, context.makeImage()!, nil); guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
    let preview = try NativeFilePreview(url: imageURL)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.alphaValue = 0; window.contentView = preview.view; window.orderBack(nil)
    defer { preview.detach(); window.close() }
    preview.prepare()
    guard let scroll = preview.focusView as? NSScrollView, let image = scroll.documentView else { throw CocoaError(.coderInvalidValue) }
    func centered() -> Bool {
        let clip = scroll.contentView
        return abs(image.frame.midX - clip.bounds.midX) < 1 && abs(image.frame.midY - clip.bounds.midY) < 1
    }
    try check("small-image-opens-centered-at-fit", centered())
    views(preview.view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "preview.larger" }?.performClick(nil)
    try check("image-remains-centered-at-magnification", centered())
    window.setContentSize(NSSize(width: 640, height: 480)); preview.view.layoutSubtreeIfNeeded()
    try check("image-remains-centered-after-resize", centered())
    try capture(preview.view, "image-preview")
    window.contentView = NSView()

    let navigation = NavigationCoordinator(backend: controller.bridge.backend)
    // Use the existing isolated navigation service; no personal locations.
    try await navigation.configure(verifying: true)
    defer { navigation.detach() }
    await navigation.addLocation(directory.path)
    try Data("needle text\n".utf8).write(to: directory.appendingPathComponent("Note.md"))
    let search = SidebarSearchController(navigation: navigation)
    defer { search.detach(); navigation.contentSearch.close() }
    window.setContentSize(NSSize(width: 268, height: 680)); window.contentView = search.view
    search.show(root: directory.path, window: nil); search.view.layoutSubtreeIfNeeded()
    guard let label = views(search.view).first(where: { $0.identifier?.rawValue == "sidebar-search-empty" }), let area = label.superview else { throw CocoaError(.coderInvalidValue) }
    try check("search-empty-instructions-are-centered-in-results-area", !label.isHidden && abs(label.frame.midX - area.bounds.midX) < 1 && abs(label.frame.midY - area.bounds.midY) < 1)
    try capture(search.view, "sidebar-search")
    navigation.contentSearch.changeQuery("needle")
    try await wait { !navigation.contentSearch.hits.isEmpty }
    try check("search-instructions-hide-when-results-arrive", label.isHidden)
    navigation.contentSearch.changeQuery("")
    try check("clearing-search-restores-instructions", !label.isHidden)
    let anchor = NSButton(title: "Sidebar", target: nil, action: nil); window.contentView = anchor
    let customization = SidebarCustomizationController(navigation: navigation)
    customization.show(relativeTo: anchor)
    guard let panel = NSApp.windows.first(where: { $0 !== window && $0.contentView.map { views($0).contains { $0.identifier?.rawValue == "sidebar-group-favorites" } } == true }), let root = panel.contentView else { throw CocoaError(.coderInvalidValue) }
    root.layoutSubtreeIfNeeded()
    let buttons = views(root).compactMap { $0 as? NSButton }
    let firstGroup = buttons.first { $0.identifier?.rawValue == "sidebar-group-favorites" }!
    try check("sidebar-customization-content-is-visible-below-header", root.bounds.contains(root.convert(firstGroup.bounds, from: firstGroup)))
    try check("sidebar-customization-explains-visible-groups-and-disables-boundary-actions", buttons.first { $0.identifier?.rawValue == "group-up-favorites" }?.isEnabled == false && buttons.first { $0.identifier?.rawValue == "group-down-recents" }?.isEnabled == false && buttons.first { $0.identifier?.rawValue == "remove-location" }?.isEnabled == false)
    let before = navigation.values.show_favorites
    buttons.first { $0.identifier?.rawValue == "sidebar-group-favorites" }?.performClick(nil)
    try await wait { navigation.values.show_favorites != before }
    try check("sidebar-checkbox-updates-shared-preferences", navigation.values.show_favorites != before)
    views(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "group-down-favorites" }?.performClick(nil)
    try await wait { navigation.values.sections.first == "locations" }
    let secondLocation = directory.appendingPathComponent("Second")
    try FileManager.default.createDirectory(at: secondLocation, withIntermediateDirectories: true)
    let canonicalSecond = await navigation.addLocation(secondLocation.path)!
    guard let locationTable = views(root).compactMap({ $0 as? NSTableView }).first else { throw CocoaError(.coderInvalidValue) }
    locationTable.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    views(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "location-up" }?.performClick(nil)
    try await wait { navigation.values.locations.first == canonicalSecond }
    views(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "remove-location" }?.performClick(nil)
    try await wait { !navigation.values.locations.contains(canonicalSecond) }
    try check("sidebar-location-reorder-and-removal-never-delete-files", FileManager.default.fileExists(atPath: secondLocation.path))
    try capture(root, "sidebar-customization")
    views(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "sidebar-customization-done" }?.performClick(nil)
    try await wait { !panel.isVisible }

    let releaseJSON = "[{\"tag_name\":\"v9.0.0\",\"prerelease\":true,\"draft\":false}]"
    let updates = UpdateCoordinator(backend: controller.bridge.backend, defaults: nil, currentVersion: "0.0.4", fetch: { _ in releaseJSON })
    var snapshot = try PreferencesCoordinator.decode(await controller.bridge.backend.perform { try $0.preferences() })
    updates.configure(snapshot.values)
    let settings = SettingsWindowController(selectLanguage: { _ in }, values: { snapshot.values }, apply: { values in
        let json = String(decoding: try JSONEncoder().encode(values), as: UTF8.self), revision = snapshot.revision
        snapshot = try PreferencesCoordinator.decode(await controller.bridge.backend.perform { try $0.updatePreferences(expectedRevision: revision, valuesJson: json) })
        updates.configure(snapshot.values)
    }, navigation: navigation, updates: updates)
    settings.selectCategory("updates"); settings.showWindow(nil); settings.window?.alphaValue = 0
    defer { settings.close(); updates.cancel() }
    guard let settingsRoot = settings.window?.contentView else { throw CocoaError(.coderInvalidValue) }
    let checkButton = views(settingsRoot).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "check-updates" }!
    checkButton.performClick(nil)
    try await wait { if case .checked = updates.state { return true }; return false }
    if case .checked(let result) = updates.state { try check("settings-check-updates-routes-through-real-rust-version-comparison", result.newer && result.release?.version == "v9.0.0") }
    try check("settings-check-action-recovers-after-request", checkButton.isEnabled)
    try capture(settingsRoot, "updates-settings")
    views(settingsRoot).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "updates.includeBeta" }?.performClick(nil)
    try await wait { !snapshot.values.include_prerelease_updates && !settings.applyingLanguage }
    views(settingsRoot).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "check-updates" }?.performClick(nil)
    try await wait { if case .checked(let result) = updates.state { return result.release == nil }; return false }
    try check("stable-channel-does-not-claim-beta-is-an-update", { if case .checked(let result) = updates.state { return !result.newer }; return false }())
    let attempts = ReleaseAttemptFixture()
    let failed = UpdateCoordinator(backend: controller.bridge.backend, defaults: nil, fetch: { _ in try await attempts.fetch() })
    failed.check(); failed.check()
    try await wait { if case .failed = failed.state { return true }; return false }
    try check("offline-update-check-keeps-failure-visible", failed.lastChecked == nil)
    try check("duplicate-update-actions-share-one-request", await attempts.attempts == 1)
    failed.check()
    try await wait { if case .checked = failed.state { return true }; return false }
    try check("failed-update-check-can-be-retried", failed.lastChecked != nil)
    failed.cancel()
    let delayed = UpdateCoordinator(backend: controller.bridge.backend, defaults: nil, currentVersion: "0.0.4", fetch: { _ in try? await Task.sleep(for: .milliseconds(80)); return releaseJSON })
    delayed.configure(snapshot.values); delayed.check()
    var changedChannel = snapshot.values; changedChannel.include_prerelease_updates.toggle(); delayed.configure(changedChannel)
    try await Task.sleep(for: .milliseconds(120))
    try check("changing-update-channel-rejects-old-results", { if case .idle = delayed.state { return true }; return false }())
    try check("native-menus-have-no-conflicting-markdown-shortcuts", EditorShortcuts.bindings.count == 36 && Set(EditorShortcuts.bindings.map { $0.modifiers.sorted().joined() + $0.key }).count == EditorShortcuts.bindings.count)
    return passed
}
