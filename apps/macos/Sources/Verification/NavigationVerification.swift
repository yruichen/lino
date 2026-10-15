import AppKit
import WebKit

@MainActor
func verifyNavigationFlow(_ controller: EditorWindowController, navigation: NavigationCoordinator) async throws -> [String] {
    var passed: [String] = []
    func check(_ name: String, _ condition: Bool) throws {
        guard condition else { throw NSError(domain: "NavigationVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }; passed.append(name)
    }
    guard let window = controller.window else { throw NSError(domain: "NavigationVerification", code: 2) }
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(controller.webView)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lino-navigation-fixtures-\(UUID().uuidString)")
    defer { controller.quickOpen.dismiss(); try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("Personal"), second = directory.appendingPathComponent("Studio")
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    let one = first.appendingPathComponent("Ideas.md"), two = second.appendingPathComponent("Ideas.md")
    try Data("# Writing Principles\n\nA quiet place to think, collect ideas, and return to the words that matter.\n\n## Make room for a thought\n\nKeep the page simple. Let the next sentence arrive at its own pace. A good tool leaves enough room for your attention.\n\n## Find your way back\n\nNotes are easier to revisit when their names say what they contain. Search when you know the name; browse when you want to explore.\n\n| A | B |\n| --- | --- |\n| C | D |\n".utf8).write(to: one)
    try Data("# Writing Principles\n\nAnother quiet place.\n".utf8).write(to: two)
    try Data("# Daily Notes\n".utf8).write(to: first.appendingPathComponent("Daily Notes.md"))
    try Data("# Reading List\n".utf8).write(to: first.appendingPathComponent("Reading List.md"))
    await navigation.addLocation(first.path); await navigation.addLocation(second.path)
    await navigation.noteFile(one.path); await navigation.noteFile(two.path)
    func waitResults(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while controller.quickOpen.results.count != count && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try check("native-quick-open-result-count-\(count)", controller.quickOpen.results.count == count)
    }
    let before = try await controller.bridge.call("snapshot") as? [String: Any] ?? [:]
    let selection = try JSONSerialization.data(withJSONObject: before["selection"] ?? [], options: [.sortedKeys])
    controller.quickOpen.show(); controller.quickOpen.field.stringValue = ""; controller.quickOpen.refreshSearch()
    try await waitResults(2)
    try check("native-quick-open-recents-cross-workspaces", Set(controller.quickOpen.results.map { $0.path }).count == 2)
    try check("native-quick-open-input-focus", controller.quickOpen.field.window?.firstResponder === controller.quickOpen.field.window?.fieldEditor(false, for: controller.quickOpen.field))
    let path = controller.quickOpen.results[0].path
    var opened: String?
    let oldOpen = controller.quickOpen.onOpen; controller.quickOpen.onOpen = { path, _ in opened = path }
    defer { controller.quickOpen.onOpen = oldOpen }
    _ = controller.quickOpen.control(controller.quickOpen.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
    try check("native-quick-open-enter-opens-selected-and-dismisses", opened == path && !controller.quickOpen.visible)
    controller.quickOpen.show(); controller.quickOpen.field.stringValue = "Ideas"; controller.quickOpen.refreshSearch()
    try await waitResults(1)
    controller.quickOpen.dismiss()
    let after = try await controller.bridge.call("snapshot") as? [String: Any] ?? [:]
    try check("native-quick-open-cancel-keeps-document-and-selection", before["text"] as? String == after["text"] as? String && selection == (try JSONSerialization.data(withJSONObject: after["selection"] ?? [], options: [.sortedKeys])))
    controller.setWorkspaceVisible(true)
    let originalSize = window.frame; defer { window.setFrame(originalSize, display: false); controller.setWorkspaceVisible(false) }
    window.setContentSize(NSSize(width: 640, height: 480)); window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(220))
    try check("native-narrow-sidebar-occupies-space-and-preserves-writing-width", (controller.webView.superview?.frame.width ?? 0) >= 320 && (controller.webView.superview?.frame.minX ?? 0) >= 230)
    window.setContentSize(NSSize(width: 1080, height: 780)); window.contentView?.layoutSubtreeIfNeeded()
    let roots = (0..<controller.workspace.outline.numberOfRows).compactMap { controller.workspace.outline.item(atRow: $0) as? NavigationItem }.filter { $0.directory }
    for root in roots { controller.workspace.outline.expandItem(root) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while controller.workspace.outline.numberOfRows < 1 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    try check("native-locations-use-source-list", controller.workspace.outline.style == .sourceList && controller.workspace.outline.numberOfRows >= 1)
    controller.quickOpen.show(); controller.quickOpen.field.stringValue = "Ideas"; controller.quickOpen.refreshSearch(); try await waitResults(1)
    window.contentView?.layoutSubtreeIfNeeded()
    let tabs = DocumentWindows(verifying: true)
    try await tabs.navigation.configure(verifying: true)
    await tabs.navigation.addLocation(first.path); await tabs.navigation.addLocation(second.path)
    defer { tabs.detach(); for document in tabs.controllers { document.documents.cleanupVerificationFiles(); document.window?.close() } }
    let source = tabs.create(path: one.path)
    source.workspace.setOutline(true)
    func waitReady(_ target: EditorWindowController) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !target.documents.ready && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try check("native-navigation-document-ready", target.documents.ready)
    }
    try await waitReady(source)
    let outlineDeadline = ContinuousClock.now.advanced(by: .seconds(3))
    while source.workspace.outline.numberOfRows < 3 && ContinuousClock.now < outlineDeadline { try await Task.sleep(for: .milliseconds(20)) }
    try check("native-outline-restores-on-first-document-open", source.workspace.outline.numberOfRows == 3)
    source.setWorkspaceVisible(true)
    let beforeFind = try await source.bridge.call("snapshot") as? [String: Any] ?? [:]
    source.searchControls.open()
    try await Task.sleep(for: .milliseconds(220))
    let searchField = source.searchControls.item.searchField
    try check("native-document-search-focuses-system-field", source.window?.firstResponder === source.window?.fieldEditor(false, for: searchField))
    searchField.stringValue = "Writing"
    source.searchControls.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
    try await Task.sleep(for: .milliseconds(80))
    searchField.stringValue = ""
    source.searchControls.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
    try await Task.sleep(for: .milliseconds(80))
    let cleared = try await source.bridge.call("snapshot") as? [String: Any] ?? [:]
    try check("native-document-search-clear-keeps-search-open", (cleared["search"] as? [String: Any])?["open"] as? Bool == true)
    _ = source.searchControls.control(searchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    try await Task.sleep(for: .milliseconds(80))
    let afterFind = try await source.bridge.call("snapshot") as? [String: Any] ?? [:]
    try check("native-document-search-escape-keeps-selection", (try JSONSerialization.data(withJSONObject: beforeFind["selection"] ?? [], options: [.sortedKeys])) == (try JSONSerialization.data(withJSONObject: afterFind["selection"] ?? [], options: [.sortedKeys])))
    try check("native-document-search-escape-restores-editor-focus", source.window?.firstResponder === source.webView)
    source.workspace.setOutline(true); source.setWorkspaceVisible(true)
    source.quickOpen.show(); source.quickOpen.field.stringValue = "Daily"; source.quickOpen.refreshSearch()
    let screenshotDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    while source.quickOpen.results.isEmpty && ContinuousClock.now < screenshotDeadline { try await Task.sleep(for: .milliseconds(20)) }
    source.window?.appearance = NSAppearance(named: .aqua)
    try await Task.sleep(for: .milliseconds(220))
    // Capture only the isolated fixture window's AppKit content for visual review.
    if let content = source.window?.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
        content.cacheDisplay(in: content.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/validation/quiet-navigation.png")
            try png.write(to: output)
        }
    }
    source.quickOpen.dismiss()
    _ = try await source.bridge.call("verifyDocumentEdit")
    let original = try await source.bridge.call("snapshot") as? [String: Any] ?? [:]
    await tabs.open(path: two.path, origin: source)
    guard let target = tabs.controllers.last, target !== source else { throw NSError(domain: "NavigationVerification", code: 3) }
    try await waitReady(target)
    try check("native-sidebar-opens-file-in-existing-native-tab-group", source.window?.tabbedWindows?.contains(where: { $0 === target.window }) == true)
    try check("native-new-document-shares-sidebar-presentation", target.workspaceVisible && target.workspace.showingOutline == source.workspace.showingOutline && target.window?.tabbingMode == .disallowed)
    await tabs.open(path: one.path, origin: target)
    let returned = try await source.bridge.call("snapshot") as? [String: Any] ?? [:]
    try check("native-navigation-return-keeps-dirty-text-and-undo", original["text"] as? String == returned["text"] as? String && returned["dirty"] as? Bool == true && returned["canUndo"] as? Bool == true)
    try check("native-navigation-return-keeps-selection", (try JSONSerialization.data(withJSONObject: original["selection"] ?? [], options: [.sortedKeys])) == (try JSONSerialization.data(withJSONObject: returned["selection"] ?? [], options: [.sortedKeys])))
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let dropped = directory.appendingPathComponent("dropped.png")
    try bitmap.representation(using: .png, properties: [:])!.write(to: dropped)
    target.window?.makeKeyAndOrderFront(nil)
    let point = try await target.webView.callAsyncJavaScript("const r = document.querySelector('.cm-content').getBoundingClientRect(); return {x:r.left+16, y:r.top+12};", arguments: [:], in: nil, contentWorld: .page) as? [String: Double] ?? [:]
    target.webView.onImageDrop?([dropped.path], NSPoint(x: point["x"] ?? 40, y: point["y"] ?? 40))
    let imageDeadline = ContinuousClock.now.advanced(by: .seconds(3))
    var imageText = ""
    while ContinuousClock.now < imageDeadline {
        imageText = (try await target.bridge.call("snapshot") as? [String: Any])?["text"] as? String ?? ""
        if imageText.contains(dropped.resolvingSymlinksInPath().path) { break }; try await Task.sleep(for: .milliseconds(20))
    }
    try check("native-image-drop-imports-and-inserts-markdown", imageText.contains(dropped.resolvingSymlinksInPath().path) && FileManager.default.fileExists(atPath: dropped.path))
    let unsupported = directory.appendingPathComponent("book.pdf")
    try Data("not a markdown file".utf8).write(to: unsupported)
    let count = tabs.controllers.count
    await tabs.open(path: unsupported.path, origin: target)
    try check("native-unsupported-file-does-not-create-a-window", tabs.controllers.count == count && target.window?.attachedSheet != nil)
    if let sheet = target.window?.attachedSheet { target.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
    source.window?.makeKeyAndOrderFront(nil)
    // Exercise the actual sheet decisions in this isolated window. Cancelling
    // must release the replacement freeze and permit the next close request.
    func decideSheet(_ index: Int, in target: NSWindow) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while target.attachedSheet == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard let sheet = target.attachedSheet else { throw NSError(domain: "NavigationVerification", code: 4) }
        func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        let choices = buttons(sheet.contentView!).filter { $0.title == localized(index == 1 ? "dialog.keepEditing" : "dialog.discardClose") }
        try check("native-close-sheet-explicit-choices", choices.count == 1)
        choices[0].performClick(nil)
    }
    let cancel = Task { await source.documents.prepareClose() }
    try await decideSheet(1, in: source.window!)
    try check("native-close-cancel-releases-busy-state", await cancel.value == false && !source.documents.busy)
    let close = Task { await source.documents.prepareClose() }
    try await decideSheet(2, in: source.window!)
    try check("native-close-can-be-repeated-after-cancel", await close.value)
    try check("native-close-discard-completes", await source.documents.commitClose())
    return passed
}

/// Focused coverage of the user's presentation triggers, without editor-wide fixtures.
@MainActor
func verifyNavigationPresentation(_ windows: DocumentWindows) async throws -> [String] {
    var passed: [String] = []
    func check(_ name: String, _ condition: Bool) throws {
        guard condition else { throw NSError(domain: "NavigationPresentation", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
        passed.append(name)
    }
    func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard condition() else { throw NSError(domain: "NavigationPresentation", code: 2, userInfo: [NSLocalizedDescriptionKey: "Fixture did not become ready"]) }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lino-navigation-presentation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let first = directory.appendingPathComponent("Writing.md"), second = directory.appendingPathComponent("Notes.md")
    try Data(("# Writing\n\n" + String(repeating: "A quiet place to write, with room for each thought.\n\n", count: 60) + "## Return\n").utf8).write(to: first)
    try Data("# Notes\n\nKeep a thought.\n".utf8).write(to: second)
    let initialCount = windows.controllers.count
    defer {
        for document in windows.controllers.dropFirst(initialCount) { document.detach(); document.documents.cleanupVerificationFiles(); document.window?.close() }
        try? FileManager.default.removeItem(at: directory)
    }
    let source = windows.create()
    try await wait { source.documents.ready }
    guard let window = source.window, let split = Optional(source.navigationSplit) else { throw NSError(domain: "NavigationPresentation", code: 3) }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    try await wait { NSApp.isActive && window.isKeyWindow }
    await windows.navigation.addLocation(directory.path)
    source.setWorkspaceVisible(true); try await Task.sleep(for: .milliseconds(240))
    let frame = window.frame, sidebarWidth = split.sidebarPane.frame.width
    source.workspace.setOutline(true)
    await windows.open(path: first.path, origin: source)
    let opened = try await source.bridge.call("snapshot") as? [String: Any] ?? [:]
    try check("first-file-reuses-pristine-page-without-window-tab-or-sidebar-resize", windows.controllers.count == initialCount + 1 && source.documents.hasFile && opened["text"] as? String == (try String(contentsOf: first, encoding: .utf8)) && window.frame == frame && split.sidebarPane.frame.width == sidebarWidth)
    try await wait { source.workspace.outline.numberOfRows == 2 }
    try check("reused-page-outline-is-ready-without-changing-sidebar-page", source.workspace.showingOutline && source.workspace.outline.numberOfRows == 2)
    source.workspace.setOutline(false)
    try await Task.sleep(for: .milliseconds(150))
    let outline = source.workspace.outline
    try await wait { outline.numberOfRows > 0 }
    outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    var preferences = try PreferencesCoordinator.decode(await windows.backend.perform { try $0.preferences() })
    preferences.values.theme_family = "grove"
    func selectedUsesNativePresentation() -> Bool {
        guard let row = outline.rowView(atRow: outline.selectedRow, makeIfNecessary: true) else { return false }
        return row.isSelected && outline.selectionHighlightStyle == .regular
    }
    let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    defer { other.close() }
    for appearance in ["light", "dark"] {
        preferences.values.theme = appearance
        window.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        ThemePalette.install(preferences.values)
        try await source.documents.applyPreferences(preferences.json())
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(outline)
        try await Task.sleep(for: .milliseconds(80))
        let activePaint = window.isKeyWindow && NSApp.isActive && selectedUsesNativePresentation()
        other.makeKeyAndOrderFront(nil); try await Task.sleep(for: .milliseconds(40))
        try check("native-file-selection-follows-\(appearance)-theme-in-active-and-inactive-windows", activePaint && !window.isKeyWindow && selectedUsesNativePresentation())
    }
    window.makeKeyAndOrderFront(nil); window.makeFirstResponder(source.webView)
    _ = try await source.bridge.call("focusEditor")
    _ = try await source.webView.callAsyncJavaScript("document.querySelector('.cm-scroller').scrollTop = 420;", arguments: [:], in: nil, contentWorld: .page)
    let before = try await source.bridge.call("snapshot") as? [String: Any] ?? [:]
    let scrollBefore = try await source.webView.callAsyncJavaScript("return document.querySelector('.cm-scroller').scrollTop", arguments: [:], in: nil, contentWorld: .page) as? Double ?? 0
    let backingWidth = source.webView.frame.width
    var covered = true, stableTree = true, sawIntermediate = false, centered = true
    func sample() async throws {
        let visible = split.arrangedSubviews.first?.frame.width ?? 0
        sawIntermediate = sawIntermediate || (visible > 1 && visible < sidebarWidth - 1)
        let backing = split.convert(source.webView.bounds, from: source.webView)
        covered = covered && source.webView.frame.width == backingWidth && backing.maxX >= split.bounds.maxX && backing.minX >= 0 && split.layer?.masksToBounds == true && source.webView.superview?.layer?.masksToBounds == true && abs(split.convert(split.editorPane.bounds, from: split.editorPane).maxX - split.bounds.maxX) < 0.1
        stableTree = stableTree && split.sidebarPane.subviews.first?.frame.width == sidebarWidth
        let center = try await source.webView.callAsyncJavaScript("const r=document.querySelector('.cm-content').getBoundingClientRect(); return r.left+r.width/2;", arguments: [:], in: nil, contentWorld: .page) as? Double ?? -1
        let currentBacking = split.convert(source.webView.bounds, from: source.webView)
        centered = centered && abs(currentBacking.minX + center - split.convert(split.editorPane.bounds, from: split.editorPane).midX) < 1

    }
    source.setWorkspaceVisible(false)
    for _ in 0..<14 { try await sample(); try await Task.sleep(for: .milliseconds(16)) }
    source.setWorkspaceVisible(true)
    for _ in 0..<4 { try await sample(); try await Task.sleep(for: .milliseconds(16)) }
    source.setWorkspaceVisible(false)
    for _ in 0..<14 { try await sample(); try await Task.sleep(for: .milliseconds(16)) }
    try check("collapse-and-reversal-cover-right-edge-with-stable-backing-and-tree-throughout-animation", covered && stableTree && sawIntermediate && split.controller.splitViewItems.first?.isCollapsed == true && source.webView.frame.minX == 0)
    try check("writing-center-follows-pane-through-animation-without-final-rebound", centered)
    let after = try await source.bridge.call("snapshot") as? [String: Any] ?? [:]
    let geometry = try await source.webView.callAsyncJavaScript("const s=document.querySelector('.cm-scroller'), e=document.querySelector('.cm-editor'); return {width:e.getBoundingClientRect().width, left:s.scrollLeft, top:s.scrollTop};", arguments: [:], in: nil, contentWorld: .page) as? [String: Double] ?? [:]
    try check("sidebar-visibility-keeps-writing-position-and-final-viewport", before["text"] as? String == after["text"] as? String && (try JSONSerialization.data(withJSONObject: before["selection"] ?? [], options: [.sortedKeys])) == (try JSONSerialization.data(withJSONObject: after["selection"] ?? [], options: [.sortedKeys])) && geometry["left"] == 0 && abs((geometry["top"] ?? -1) - scrollBefore) < 2 && abs((geometry["width"] ?? 0) - split.viewportWidth) < 1)
    source.setWorkspaceVisible(true); try await Task.sleep(for: .milliseconds(75))
    let snapshot = WKSnapshotConfiguration(); snapshot.rect = NSRect(x: split.viewportWidth - 12, y: 50, width: 8, height: 8)
    let image = try await source.webView.takeSnapshot(configuration: snapshot)
    let pixel = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB) }
    try check("web-content-right-edge-remains-dark-during-sidebar-reveal", pixel.map { max($0.redComponent, $0.greenComponent, $0.blueComponent) < 0.8 } == true)
    try await Task.sleep(for: .milliseconds(200))
    let nativeFrame = window.frame
    await windows.open(path: second.path, origin: source)
    guard let target = windows.controllers.last, target !== source else { throw NSError(domain: "NavigationPresentation", code: 4) }
    try await wait { target.documents.ready }
    let sourceAfterTab = try await source.bridge.call("snapshot") as? [String: Any] ?? [:]
    try check("bound-page-opens-next-file-in-same-frame-native-tab-preserving-source", window.tabbedWindows?.contains(where: { $0 === target.window }) == true && target.window?.frame == window.frame && abs(window.frame.minX - nativeFrame.minX) < 1 && abs(window.frame.maxY - nativeFrame.maxY) < 1 && source.workspaceVisible && sourceAfterTab["text"] as? String == before["text"] as? String)
    let beforeReopen = windows.controllers.count
    window.miniaturize(nil)
    _ = (NSApp.delegate as? EditorApplication)?.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
    try check("dock-reopen-restores-existing-document-without-creating-another", windows.controllers.count == beforeReopen && windows.controllers.contains { $0.window?.isVisible == true && $0.window?.isMiniaturized == false })
    let emptyWindows = DocumentWindows(verifying: true)
    try await emptyWindows.navigation.configure(verifying: true)
    let reopened = emptyWindows.reopen()
    try await wait { reopened?.documents.ready == true }
    try check("dock-reopen-with-no-document-creates-one-reusable-window", reopened != nil && emptyWindows.controllers.count == 1 && emptyWindows.reopen() === reopened)
    for document in emptyWindows.controllers { document.detach(); document.documents.cleanupVerificationFiles(); document.window?.close() }
    emptyWindows.navigation.detach()
    window.tabGroup?.selectedWindow = window; window.makeKeyAndOrderFront(nil)
    if let frame = window.contentView?.superview, let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/validation/quiet-navigation.png")) }
    }
    return passed
}
