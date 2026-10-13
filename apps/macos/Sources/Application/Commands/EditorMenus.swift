import AppKit

@MainActor
func installEditorMenus(target: AnyObject) {
    let menu = NSMenu()
    func section(_ title: String) -> NSMenu {
        let item = NSMenuItem()
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
    let application = section("Open Typora")
    application.addItem(withTitle: localized("menu.about"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    application.addItem(.separator())
    application.addItem(withTitle: localized("menu.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    application.addItem(.separator())
    _ = action(application, localized("menu.settings"), #selector(EditorApplication.showSettings), ",")
    application.addItem(.separator())
    application.addItem(withTitle: localized("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let file = section(localized("menu.file"))
    _ = action(file, localized("menu.new"), #selector(EditorApplication.newDocument), "n")
    _ = action(file, localized("menu.open"), #selector(EditorApplication.openDocument), "o")
    file.addItem(.separator())
    _ = action(file, localized("menu.save"), #selector(EditorApplication.saveDocument), "s")
    _ = action(file, localized("menu.saveAs"), #selector(EditorApplication.saveDocumentAs), "s", [.command, .shift])
    _ = action(file, localized("menu.autosave"), #selector(EditorApplication.toggleAutosave))
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
    let formatItem = NSMenuItem()
    formatItem.submenu = formattingMenu(target: target, action: #selector(EditorApplication.editorCommand(_:)), keyboardShortcuts: true)
    menu.addItem(formatItem)
    let view = section(localized("menu.view"))
    command(view, localized("menu.visual"), "visual", "1")
    command(view, localized("menu.source"), "source", "2")
    command(view, localized("menu.toggleSource"), "toggle-source", "/")
    view.addItem(.separator())
    _ = action(view, localized("menu.reconnect"), #selector(EditorApplication.reconnectEditor))
    NSApp.mainMenu = menu
}
