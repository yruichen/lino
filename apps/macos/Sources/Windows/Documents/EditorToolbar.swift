import AppKit

extension NSToolbarItem.Identifier {
    static let editorMode = NSToolbarItem.Identifier("editor-mode")
    static let editorFind = NSToolbarItem.Identifier("editor-find")
    static let editorFormat = NSToolbarItem.Identifier("editor-format")
}

extension EditorWindowController {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.editorMode, .flexibleSpace, .editorFormat, .editorFind]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item: NSToolbarItem
        switch identifier {
        case .editorMode:
            item = NSToolbarItem(itemIdentifier: identifier); item.view = modeControl
        case .editorFind:
            item = NSToolbarItem(itemIdentifier: identifier); item.target = self; item.action = #selector(find)
        case .editorFormat: item = NSMenuToolbarItem(itemIdentifier: identifier)
        default: return nil
        }
        localizeToolbarItem(item)
        return item
    }
    func localizeToolbarItem(_ item: NSToolbarItem) {
        switch item.itemIdentifier {
        case .editorMode: item.label = localized("editor.mode")
        case .editorFind:
            item.label = localized("editor.find"); item.toolTip = localized("editor.findTip")
            item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: localized("editor.find"))
        case .editorFormat:
            item.label = localized("format.title"); item.toolTip = localized("editor.formatTip")
            item.image = NSImage(systemSymbolName: "textformat", accessibilityDescription: localized("format.title"))
            (item as? NSMenuToolbarItem)?.menu = formattingMenu(target: self, action: #selector(formatAction(_:)))
        default: break
        }
    }
}
