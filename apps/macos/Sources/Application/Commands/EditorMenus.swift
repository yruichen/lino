import AppKit

@MainActor
func installEditorMenus(target: AnyObject) {
    let menu = NSMenu()
    func section(_ title: String) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        item.submenu = submenu; menu.addItem(item)
        return submenu
    }
    func action(_ parent: NSMenu, _ title: String, _ selector: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = parent.addItem(withTitle: title, action: selector, keyEquivalent: key)
        item.target = target; item.keyEquivalentModifierMask = modifiers
        return item
    }
    func command(_ parent: NSMenu, _ title: String, _ name: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) {
        action(parent, title, #selector(EditorApplication.editorCommand(_:)), key, modifiers).representedObject = name
    }
    let application = section("Lino")
    application.addItem(withTitle: localized("menu.about"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    application.addItem(.separator())
    _ = action(application, localized("menu.settings"), #selector(EditorApplication.showSettings), ",")
    _ = action(application, localized("updates.checkMenu"), #selector(EditorApplication.checkForUpdates))
    _ = action(application, localized("setup.openGuide"), #selector(EditorApplication.showSetup))
    application.addItem(.separator())
    let services = NSMenu(title: localized("menu.services"))
    let servicesItem = NSMenuItem(title: services.title, action: nil, keyEquivalent: ""); servicesItem.submenu = services; application.addItem(servicesItem)
    NSApp.servicesMenu = services
    application.addItem(.separator())
    application.addItem(withTitle: localized("menu.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    application.addItem(withTitle: localized("menu.hideOthers"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
    application.addItem(withTitle: localized("menu.showAll"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    application.addItem(.separator())
    application.addItem(withTitle: localized("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let file = section(localized("menu.file"))
    _ = action(file, localized("menu.new"), #selector(EditorApplication.newDocument), "n")
    _ = action(file, localized("menu.newWindow"), #selector(EditorApplication.newWindow), "n", [.command, .option])
    _ = action(file, localized("menu.open"), #selector(EditorApplication.openDocument), "o")
    _ = action(file, localized("workspace.openFolder"), #selector(EditorApplication.openFolder), "o", [.command, .shift])
    let recent = NSMenu(title: localized("workspace.recentFiles"))
    let recentItem = NSMenuItem(title: recent.title, action: nil, keyEquivalent: ""); recentItem.submenu = recent; file.addItem(recentItem)
    if let app = target as? EditorApplication { app.recentMenu = recent; recent.delegate = app }
    _ = action(file, localized("workspace.reopen"), #selector(EditorApplication.reopenClosed), "t", [.command, .shift])
    _ = action(file, localized("workspace.quick"), #selector(EditorApplication.quickOpen), "p")
    _ = action(file, localized("workspace.search"), #selector(EditorApplication.searchWorkspace), "f", [.command, .shift])
    file.addItem(.separator())
    _ = action(file, localized("menu.save"), #selector(EditorApplication.saveDocument), "s")
    _ = action(file, localized("menu.saveAs"), #selector(EditorApplication.saveDocumentAs), "s", [.command, .shift])
    _ = action(file, localized("workspace.saveAll"), #selector(EditorApplication.saveAll), "s", [.command, .option])
    _ = action(file, localized("menu.autosave"), #selector(EditorApplication.toggleAutosave))
    _ = action(file, localized("menu.reload"), #selector(EditorApplication.reloadDocument))
    _ = action(file, localized("menu.readOnly"), #selector(EditorApplication.toggleReadOnly))
    file.addItem(.separator())
    _ = action(file, localized("export.html"), #selector(EditorApplication.exportHTML))
    _ = action(file, localized("export.pdf"), #selector(EditorApplication.exportPDF))
    _ = action(file, localized("export.pageSetup"), #selector(EditorApplication.pageSetup), "p", [.command, .shift])
    _ = action(file, localized("export.print"), #selector(EditorApplication.printDocument), "p", [.command, .option])
    _ = action(file, localized("export.cancel"), #selector(EditorApplication.cancelExport))
    _ = action(file, localized("latex.compile"), #selector(EditorApplication.compileLatex))
    _ = action(file, localized("latex.cancel"), #selector(EditorApplication.cancelLatexCompile))
    file.addItem(.separator())
    _ = action(file, localized("menu.recovery"), #selector(EditorApplication.restoreDocument))
    _ = action(file, localized("menu.retry"), #selector(EditorApplication.retryPersistence))
    file.addItem(.separator())
    file.addItem(withTitle: localized("menu.close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    let edit = section(localized("menu.edit"))
    _ = action(edit, localized("menu.undo"), #selector(EditorApplication.undoEdit), "z")
    _ = action(edit, localized("menu.redo"), #selector(EditorApplication.redoEdit), "z", [.command, .shift])
    edit.addItem(.separator())
    edit.addItem(withTitle: localized("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: localized("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: localized("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: localized("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    edit.addItem(.separator())
    command(edit, localized("menu.find"), "find", "f")
    command(edit, localized("menu.replace"), "replace", "f", [.command, .option])
    command(edit, localized("menu.findNext"), "find-next", "g")
    command(edit, localized("menu.findPrevious"), "find-previous", "g", [.command, .shift])
    command(edit, localized("menu.gotoLine"), "goto-line", "g", [.command, .option])
    let formatItem = NSMenuItem(title: localized("format.title"), action: nil, keyEquivalent: "")
    formatItem.submenu = formattingMenu(
        target: target,
        action: #selector(EditorApplication.editorCommand(_:)),
        keyboardShortcuts: true,
        localize: { key, arguments in LanguagePreferences.shared.string(key, arguments: arguments) },
        applyShortcut: { command, item in EditorShortcuts.apply(command, to: item) }
    )
    menu.addItem(formatItem)
    let view = section(localized("menu.view"))
    command(view, localized("menu.visual"), "visual")
    command(view, localized("menu.source"), "source")
    command(view, localized("menu.toggleSource"), "toggle-source", "/")
    view.addItem(.separator())
    command(view, localized("writing.outline"), "toggle-outline", "o", [.command, .option])
    command(view, localized("writing.statistics"), "toggle-statistics")
    view.addItem(.separator())
    command(view, localized("writing.focus"), "focus-mode")
    command(view, localized("writing.typewriter"), "typewriter-mode")
    view.addItem(.separator())
    command(view, localized("writing.zoomIn"), "zoom-in", "+")
    command(view, localized("writing.zoomOut"), "zoom-out", "-")
    command(view, localized("writing.zoomReset"), "zoom-reset", "0", [.command, .option])
    view.addItem(.separator())
    let sidebar = NSMenu(title: localized("navigation.sidebar"))
    let sidebarEntry = NSMenuItem(title: sidebar.title, action: nil, keyEquivalent: ""); sidebarEntry.submenu = sidebar; view.addItem(sidebarEntry)
    _ = action(sidebar, localized("workspace.sidebar"), #selector(EditorApplication.toggleWorkspace), "\\")
    sidebar.addItem(.separator())
    for (key, label) in [("favorites", "navigation.showFavorites"), ("locations", "navigation.showLocations"), ("recents", "navigation.showRecents"), ("follow", "navigation.follow"), ("name", "workspace.byName"), ("modified", "workspace.byDate")] {
        action(sidebar, localized(label), #selector(EditorApplication.sidebarOption(_:))).representedObject = key
    }
    sidebar.addItem(.separator())
    _ = action(sidebar, localized("navigation.customize"), #selector(EditorApplication.customizeSidebar))
    _ = action(view, localized("workspace.cancelSearch"), #selector(EditorApplication.cancelWorkspaceSearch))
    view.addItem(withTitle: localized("writing.fullscreen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]
    view.addItem(.separator())
    _ = action(view, localized("menu.reconnect"), #selector(EditorApplication.reconnectEditor))
    let windows = section(localized("workspace.windows"))
    windows.addItem(withTitle: localized("menu.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windows.addItem(withTitle: localized("menu.zoomWindow"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    windows.addItem(.separator())
    windows.addItem(withTitle: localized("workspace.nextTab"), action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "}").keyEquivalentModifierMask = [.command, .shift]
    windows.addItem(withTitle: localized("workspace.previousTab"), action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "{").keyEquivalentModifierMask = [.command, .shift]
    windows.addItem(withTitle: localized("menu.moveTabToWindow"), action: #selector(NSWindow.moveTabToNewWindow(_:)), keyEquivalent: "")
    windows.addItem(withTitle: localized("workspace.mergeWindows"), action: #selector(NSWindow.mergeAllWindows(_:)), keyEquivalent: "")
    windows.addItem(withTitle: localized("workspace.tabBar"), action: #selector(NSWindow.toggleTabBar(_:)), keyEquivalent: "")
    windows.addItem(.separator())
    windows.addItem(withTitle: localized("menu.bringAllToFront"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
    NSApp.windowsMenu = windows
    NSApp.mainMenu = menu
}
