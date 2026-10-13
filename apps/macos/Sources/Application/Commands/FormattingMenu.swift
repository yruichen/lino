import AppKit

@MainActor
func formattingMenu(target: AnyObject, action: Selector, keyboardShortcuts: Bool = false) -> NSMenu {
    let menu = NSMenu(title: localized("format.title"))
    func add(_ parent: NSMenu, _ title: String, _ command: String, key: String = "") {
        let item = parent.addItem(withTitle: title, action: action, keyEquivalent: keyboardShortcuts ? key : "")
        item.target = target; item.representedObject = command
    }
    add(menu, localized("format.bold"), "bold", key: "b")
    add(menu, localized("format.italic"), "italic", key: "i")
    add(menu, localized("format.strikethrough"), "strikethrough")
    add(menu, localized("format.inlineCode"), "inline-code")
    add(menu, localized("format.link"), "link", key: "k")
    menu.addItem(.separator())
    let heading = NSMenu(title: localized("format.heading"))
    for level in 1...6 { add(heading, localized("format.headingLevel", level), "heading-\(level)") }
    let headingItem = NSMenuItem(title: localized("format.heading"), action: nil, keyEquivalent: "")
    headingItem.submenu = heading; menu.addItem(headingItem)
    add(menu, localized("format.bulletList"), "bullet-list")
    add(menu, localized("format.orderedList"), "ordered-list")
    add(menu, localized("format.taskList"), "task-list")
    add(menu, localized("format.blockquote"), "blockquote")
    add(menu, localized("format.codeBlock"), "code-block")
    menu.addItem(.separator())
    let table = NSMenu(title: localized("format.table"))
    for (key, command) in [
        ("format.insertTable", "insert-table"), ("format.addRow", "add-row"), ("format.addColumn", "add-column"),
        ("format.deleteRow", "delete-row"), ("format.deleteColumn", "delete-column"),
        ("format.moveRowUp", "move-row-up"), ("format.moveRowDown", "move-row-down"),
        ("format.moveColumnLeft", "move-column-left"), ("format.moveColumnRight", "move-column-right"),
        ("format.alignLeft", "align-column-left"), ("format.alignCenter", "align-column-center"),
        ("format.alignRight", "align-column-right"), ("format.deleteTable", "delete-table")
    ] { add(table, localized(key), command) }
    let tableItem = NSMenuItem(title: localized("format.table"), action: nil, keyEquivalent: "")
    tableItem.submenu = table; menu.addItem(tableItem)
    return menu
}
