import AppKit

extension NSToolbarItem.Identifier {
    static let editorTitle = NSToolbarItem.Identifier("editor-title")
    static let sidebarSeparator = NSToolbarItem.Identifier("sidebar-separator")
    static let editorFind = NSToolbarItem.Identifier("editor-find")
    static let editorCompileLatex = NSToolbarItem.Identifier("editor-compile-latex")
    static let editorWorkspace = NSToolbarItem.Identifier("editor-workspace")
}

extension EditorWindowController {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.editorWorkspace, .sidebarSeparator, .editorTitle, .flexibleSpace, .editorFind, .editorCompileLatex]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item: NSToolbarItem
        switch identifier {
        case .editorTitle:
            item = NSToolbarItem(itemIdentifier: identifier)
            titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleField.font = .systemFont(ofSize: 13, weight: .semibold)
            titleField.lineBreakMode = .byTruncatingMiddle; titleField.translatesAutoresizingMaskIntoConstraints = false
            titleField.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
            item.view = titleField
        case .sidebarSeparator:
            item = NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: navigationSplit, dividerIndex: 0)
        case .editorFind:
            item = searchControls.item
        case .editorCompileLatex:
            item = NSToolbarItem(itemIdentifier: identifier)
            item.target = self; item.action = #selector(compileLatex)
            item.image = NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: nil)
            item.isBordered = true
            if #available(macOS 15.0, *) { item.isHidden = documentKind != "latex" }
        case .editorWorkspace:
            item = NSToolbarItem(itemIdentifier: identifier); item.target = self; item.action = #selector(toggleWorkspace)
            item.isNavigational = true; item.isBordered = true
        default: return nil
        }
        localizeToolbarItem(item)
        return item
    }
    func localizeToolbarItem(_ item: NSToolbarItem) {
        if item.itemIdentifier == .editorCompileLatex, #available(macOS 15.0, *) {
            item.isHidden = documentKind != "latex"
        }
        switch item.itemIdentifier {
        case .editorWorkspace:
            item.label = localized("workspace.sidebar"); item.toolTip = localized("workspace.sidebar")
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: localized("workspace.sidebar"))
        case .editorFind:
            searchControls.relocalize()
        case .editorCompileLatex:
            item.label = localized("latex.compile"); item.toolTip = localized("latex.compile")
            item.image = NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: localized("latex.compile"))
        default: break
        }
    }
}
