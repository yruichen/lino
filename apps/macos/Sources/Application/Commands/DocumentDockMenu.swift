import AppKit

@MainActor
func documentDockMenu(documents: [EditorWindowController], active: EditorWindowController?, recentFiles: [URL], target: AnyObject) -> NSMenu {
    let menu = NSMenu(title: "Lino")
    func action(_ key: String, _ selector: Selector, in parent: NSMenu = menu) -> NSMenuItem {
        let item = parent.addItem(withTitle: localized(key), action: selector, keyEquivalent: "")
        item.target = target; return item
    }
    _ = action("menu.new", #selector(EditorApplication.newDocument))
    _ = action("menu.newWindow", #selector(EditorApplication.newWindow))
    _ = action("menu.open", #selector(EditorApplication.openDocument))
    if !recentFiles.isEmpty {
        let recent = NSMenu(title: localized("workspace.recentFiles"))
        let entry = NSMenuItem(title: recent.title, action: nil, keyEquivalent: ""); entry.submenu = recent; menu.addItem(entry)
        for url in recentFiles.prefix(10) {
            let item = recent.addItem(withTitle: url.lastPathComponent, action: #selector(EditorApplication.openRecent(_:)), keyEquivalent: "")
            item.target = target; item.representedObject = url.path; item.toolTip = url.path
        }
    }
    let available = documents.filter { !$0.documents.closed && ($0.documents.ready || $0.isPreviewing) }
    if !available.isEmpty { menu.addItem(.separator()) }
    for document in available {
        let item = menu.addItem(withTitle: document.window?.title ?? localized("document.untitled"), action: #selector(EditorApplication.activateDocument(_:)), keyEquivalent: "")
        item.target = target; item.representedObject = document
        item.state = document === active ? .on : .off
        item.toolTip = document.workspace.currentFile
    }
    return menu
}
