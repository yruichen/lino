import AppKit

@MainActor
func verifySettingsFlow(_ editor: EditorWindowController, settings: SettingsWindowController, values: () -> EditorPreferences?, navigation: NavigationCoordinator) async throws -> [String] {
    var passed: [String] = []
    func check(_ name: String, _ condition: Bool) throws {
        guard condition else { throw NSError(domain: "SettingsVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }; passed.append(name)
    }
    func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap { views($0) } }
    func settle() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while settings.applyingLanguage, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try check("settings-apply-completes", !settings.applyingLanguage && settings.lastError == nil)
        try await Task.sleep(for: .milliseconds(60))
    }
    let before = try await editor.bridge.call("snapshot") as? [String: Any] ?? [:]
    let selection = try JSONSerialization.data(withJSONObject: before["selection"] ?? [], options: [.sortedKeys])
    settings.showWindow(nil); settings.window?.makeKeyAndOrderFront(nil)
    defer { settings.close() }
    guard let root = settings.window?.contentView, let menu = views(root).compactMap({ $0 as? NSTableView }).first else { throw NSError(domain: "SettingsVerification", code: 2) }
    if CommandLine.arguments.contains("--layout-only") {
        guard let window = settings.window else { throw NSError(domain: "SettingsVerification", code: 2) }
        let selectionOnly = CommandLine.arguments.contains("--selection-only")
        menu.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false); root.layoutSubtreeIfNeeded()
        let grove = views(root).compactMap { $0 as? ThemeChoiceButton }.first { $0.definition.id == "grove" }!
        _ = grove.sendAction(grove.action, to: grove.target); try await settle()
        let mode = views(root).compactMap { $0 as? NSPopUpButton }.first { $0.itemArray.contains { $0.representedObject as? String == "light" } }!
        mode.selectItem(at: mode.itemArray.firstIndex { $0.representedObject as? String == "light" }!); _ = mode.sendAction(mode.action, to: mode.target); try await settle()
        if !selectionOnly {
        for size in [NSSize(width: 800, height: 700), NSSize(width: 900, height: 1000)] {
            window.setContentSize(size)
            var aligned = true
            for row in 0..<menu.numberOfRows {
                menu.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); root.layoutSubtreeIfNeeded()
                guard let title = views(root).compactMap({ $0 as? NSTextField }).first(where: { $0.font?.pointSize == 23 }) else { aligned = false; continue }
                let rect = root.convert(title.bounds, from: title)
                let guide = window.contentLayoutGuide as! NSLayoutGuide
                let top = guide.frame.maxY - rect.maxY
                aligned = aligned && abs(top - 28) < 2
            }
            try check("settings-all-categories-start-at-top-height-\(Int(size.height))", aligned)
        }
        try check("settings-and-editor-native-titlebars-follow-theme", window.titlebarAppearsTransparent && editor.window?.titlebarAppearsTransparent == true && window.titlebarSeparatorStyle == .none)
        let backdrop = try await editor.webView.callAsyncJavaScript("const read = s => getComputedStyle(document.querySelector(s)).backgroundColor; return {page:read('html'), body:read('body'), editor:read('.cm-editor'), scroll:read('.cm-scroller'), overscroll:getComputedStyle(document.querySelector('.cm-scroller')).overscrollBehaviorY};", arguments: [:], in: nil, contentWorld: .page) as? [String: String] ?? [:]
        try check("editor-elastic-scroll-has-themed-backdrop-at-every-layer", backdrop["page"] == backdrop["editor"] && backdrop["body"] == backdrop["editor"] && backdrop["scroll"] == backdrop["editor"] && backdrop["overscroll"] == "contain" && editor.webView.layer?.backgroundColor != nil)
        editor.window?.makeKeyAndOrderFront(nil)
        editor.setWorkspaceVisible(true); try await Task.sleep(for: .milliseconds(220))
        editor.setWorkspaceVisible(false); try await Task.sleep(for: .milliseconds(80))
        guard let split = editor.webView.superview?.superview as? NavigationSplitView else { throw NSError(domain: "SettingsVerification", code: 3) }
        let stableTreeWidth = split.subviews[0].subviews.first?.frame.width ?? 0
        editor.setWorkspaceVisible(true); try await Task.sleep(for: .milliseconds(50))
        editor.setWorkspaceVisible(false); try await Task.sleep(for: .milliseconds(220))
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        let scrollLeft = try await editor.webView.callAsyncJavaScript("return document.querySelector('.cm-scroller').scrollLeft;", arguments: [:], in: nil, contentWorld: .page) as? Double ?? -1
        try check("sidebar-collapse-and-reversal-leave-no-strip-or-horizontal-pull", stableTreeWidth >= 230 && split.subviews[0].isHidden && split.subviews[0].frame.width == 0 && editor.webView.frame.minX == 0 && scrollLeft == 0)
        }
        editor.window?.makeKeyAndOrderFront(nil)
        editor.setWorkspaceVisible(true); try await Task.sleep(for: .milliseconds(220))
        try check("sidebar-selection-controls-use-theme-presentation", views(editor.workspace.view).contains { $0 is NSSegmentedControl })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lino-appearance-fixture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("# Writing\n".utf8).write(to: directory.appendingPathComponent("Writing.md"))
        await navigation.addLocation(directory.path)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        func fileRow() -> Int? { (0..<editor.workspace.outline.numberOfRows).first { row in
            guard let item = editor.workspace.outline.item(atRow: row) as? NavigationItem else { return false }
            return item.section == nil && !item.directory
        } }
        while fileRow() == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if let row = fileRow() { editor.workspace.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        try check("sidebar-selected-file-uses-native-selection", editor.workspace.outline.selectedRow >= 0 && editor.workspace.outline.selectionHighlightStyle == .regular)
        if let frame = editor.window?.contentView?.superview, let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) { frame.cacheDisplay(in: frame.bounds, to: bitmap); if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/validation/quiet-navigation.png")) } }
        menu.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); root.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil)
        let frame = root.superview ?? root
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/validation/settings.png")
        if let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) { frame.cacheDisplay(in: frame.bounds, to: bitmap); if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: output) } }
        return passed
    }
    menu.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false); root.layoutSubtreeIfNeeded()
    let cards = views(root).compactMap { $0 as? ThemeChoiceButton }
    try check("settings-six-paired-themes-from-bundled-catalog", cards.count == 6 && Set(cards.map { $0.definition.id }).count == 6)
    let book = cards.first { $0.definition.id == "book" }!
    _ = book.sendAction(book.action, to: book.target); try await settle()
    try check("settings-theme-card-updates-shared-preference", values()?.theme_family == "book")
    let mode = views(root).compactMap { $0 as? NSPopUpButton }.first { $0.itemArray.contains { $0.representedObject as? String == "dark" } }!
    mode.selectItem(at: mode.itemArray.firstIndex { $0.representedObject as? String == "dark" }!)
    _ = mode.sendAction(mode.action, to: mode.target); try await settle()
    let color = try await editor.bridge.call("snapshot") as? [String: Any] ?? [:]
    try check("settings-theme-keeps-document-and-selection", color["text"] as? String == before["text"] as? String && selection == (try JSONSerialization.data(withJSONObject: color["selection"] ?? [], options: [.sortedKeys])))
    try check("settings-native-and-editor-share-selected-family", ThemePalette.current.id == "book" && values()?.theme == "dark")
    menu.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false); root.layoutSubtreeIfNeeded()
    let font = views(root).compactMap { $0 as? NSComboBox }.first!
    font.stringValue = "Georgia"; _ = font.sendAction(font.action, to: font.target); try await settle()
    try check("settings-body-font-control-persists", values()?.body_font == "Georgia")
    settings.importDefinition(Data("{\"not-a-theme\":true}".utf8))
    try check("settings-malformed-import-keeps-effective-theme", settings.lastError != nil && values()?.theme_family == "book")
    var custom = ThemePalette.builtins[0]; custom.id = "custom-verification"; custom.name = "Verification"; custom.dark.colors["bg"] = "#26343A"
    settings.importDefinition(try JSONEncoder().encode(custom)); try await settle()
    try check("settings-diy-import-reaches-shared-store-and-native-palette", values()?.custom_themes.first?.id == custom.id && ThemePalette.current.dark.colors["bg"] == "#26343A")
    for row in [0, 3, 4, 5] { menu.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); root.layoutSubtreeIfNeeded(); try check("settings-category-\(row)-has-working-content", settings.selectedCategory != "appearance" && views(root).count > 20) }
    menu.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false); root.layoutSubtreeIfNeeded()
    let remove = views(root).compactMap { $0 as? NSButton }.first { $0.title == localized("settings.removeTheme") }!
    _ = remove.sendAction(remove.action, to: remove.target); try await settle()
    try check("settings-removing-diy-theme-restores-paper-and-keeps-original-template-independent", values()?.theme_family == "paper" && values()?.custom_themes.isEmpty == true)
    let mode2 = views(root).compactMap { $0 as? NSPopUpButton }.first { $0.itemArray.contains { $0.representedObject as? String == "light" } }!
    mode2.selectItem(at: mode2.itemArray.firstIndex { $0.representedObject as? String == "light" }!); _ = mode2.sendAction(mode2.action, to: mode2.target); try await settle()
    root.layoutSubtreeIfNeeded()
    try check("settings-selected-category-survives-theme-changes", menu.selectedRow == 1)
    let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/validation/settings.png")
    if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) { root.cacheDisplay(in: root.bounds, to: bitmap); if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: output) } }
    return passed
}

@MainActor
func verifyAppearanceControls(_ editor: EditorWindowController, settings: SettingsWindowController, values: () -> EditorPreferences?) async throws -> [String] {
    var passed: [String] = []
    func check(_ name: String, _ condition: Bool) throws {
        guard condition else { throw NSError(domain: "AppearanceVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }; passed.append(name)
    }
    func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap { views($0) } }
    func settle() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while settings.applyingLanguage, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard !settings.applyingLanguage && settings.lastError == nil else { throw NSError(domain: "AppearanceVerification", code: 2, userInfo: [NSLocalizedDescriptionKey: settings.lastError ?? "Preference did not complete"]) }
    }
    settings.showWindow(nil)
    defer { settings.close() }
    let root = settings.window!.contentView!, menu = views(root).compactMap { $0 as? NSTableView }.first!
    menu.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lino-background-fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let image = directory.appendingPathComponent("Backdrop.png")
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 12, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<12 { for x in 0..<12 { bitmap.setColor(.systemBlue, atX: x, y: y) } }
    try bitmap.representation(using: .png, properties: [:])!.write(to: image)
    let before = try await editor.bridge.call("snapshot") as? [String: Any] ?? [:]
    settings.applyBackgroundSelection(image); try await settle()
    let loaded = try await editor.webView.callAsyncJavaScript(#"const e=document.querySelector('.cm-editor'); const src=e.style.getPropertyValue('--ot-background-image').match(/^url\("(.+)"\)$/)?.[1]; if(!src)return false; const i=new Image(); i.src=src; await i.decode(); return e.dataset.backgroundImage==='true'&&i.naturalWidth===12;"#, arguments: [:], in: nil, contentWorld: .page) as? Bool == true
    try check("selected-background-bookmark-loads-through-host-resource-without-copying", loaded && values()?.background_image.isEmpty == false && (try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)).count == 1)
    let uri = try await editor.webView.callAsyncJavaScript("return document.querySelector('.cm-editor').style.getPropertyValue('--ot-background-image');", arguments: [:], in: nil, contentWorld: .page) as? String
    let opacity = views(root).compactMap { $0 as? NSSlider }.first { $0.integerValue == 20 }!
    opacity.integerValue = 15; _ = opacity.sendAction(opacity.action, to: opacity.target); try await settle()
    let afterURI = try await editor.webView.callAsyncJavaScript("return document.querySelector('.cm-editor').style.getPropertyValue('--ot-background-image');", arguments: [:], in: nil, contentWorld: .page) as? String
    let alpha = try await editor.webView.callAsyncJavaScript("return Number(getComputedStyle(document.querySelector('.cm-editor'),'::before').opacity);", arguments: [:], in: nil, contentWorld: .page) as? Double ?? -1
    try check("background-opacity-control-persists-without-reloading-the-image", values()?.background_opacity == 15 && uri == afterURI && abs(alpha - 0.15) < 0.001)
    let material = views(root).compactMap { $0 as? NSPopUpButton }.first { $0.itemArray.contains { $0.representedObject as? String == "clear" } }!
    material.selectItem(at: material.itemArray.firstIndex { $0.representedObject as? String == "clear" }!); _ = material.sendAction(material.action, to: material.target); try await settle()
    let rendered: Bool
    if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency { rendered = ThemePalette.navigationStyle == "solid" }
    else if #available(macOS 26, *) { rendered = views(editor.window!.contentView!).contains { ($0 as? NSGlassEffectView)?.style == .clear } }
    else { rendered = views(editor.window!.contentView!).contains { $0 is NSVisualEffectView } }
    try check("glass-setting-reaches-real-native-material-and-preview", values()?.glass_style == "clear" && rendered && views(root).contains { $0 is AppearancePreviewView })
    let remove = views(root).compactMap { $0 as? NSButton }.first { $0.title == localized("settings.removeBackground") }!
    _ = remove.sendAction(remove.action, to: remove.target); try await settle()
    let after = try await editor.bridge.call("snapshot") as? [String: Any] ?? [:]
    try check("removing-background-keeps-original-image-and-writing-session", values()?.background_image == "" && FileManager.default.fileExists(atPath: image.path) && before["text"] as? String == after["text"] as? String && before["dirty"] as? Bool == after["dirty"] as? Bool)
    menu.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false); root.layoutSubtreeIfNeeded()
    if let frame = root.superview, let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/validation/settings.png")) }
    }
    return passed
}
