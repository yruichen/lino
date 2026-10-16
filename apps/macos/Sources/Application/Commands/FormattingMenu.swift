import AppKit

@MainActor
func formattingMenu(target: AnyObject, action: Selector, keyboardShortcuts: Bool = false) -> NSMenu {
    let menu = NSMenu(title: localized("format.title"))
    func add(_ parent: NSMenu, _ title: String, _ command: String, key: String = "") {
        let item = parent.addItem(withTitle: title, action: action, keyEquivalent: keyboardShortcuts ? key : "")
        item.target = target; item.representedObject = command
        if keyboardShortcuts { EditorShortcuts.apply(command, to: item) }
    }
    func group(_ key: String, _ items: [(String, String)], into parent: NSMenu = menu) {
        let submenu = NSMenu(title: localized(key))
        for (title, command) in items { add(submenu, localized(title), command) }
        let item = NSMenuItem(title: localized(key), action: nil, keyEquivalent: "")
        item.submenu = submenu; parent.addItem(item)
    }
    add(menu, localized("format.bold"), "bold", key: "b")
    add(menu, localized("format.italic"), "italic", key: "i")
    add(menu, localized("format.strikethrough"), "strikethrough")
    add(menu, localized("format.inlineCode"), "inline-code")
    group("format.textStyle", [("format.highlight", "highlight"), ("format.superscript", "superscript"), ("format.subscript", "subscript"), ("format.clearInline", "clear-formatting")])
    add(menu, localized("format.link"), "link", key: "k")
    group("format.linkOptions", [("link.properties", "link-properties"), ("link.open", "open-link"), ("link.copy", "copy-link"), ("link.remove", "unlink"), ("link.definition", "edit-link-reference")])
    menu.addItem(.separator())
    let heading = NSMenu(title: localized("format.heading"))
    for level in 1...6 { add(heading, localized("format.headingLevel", level), "heading-\(level)") }
    let headingItem = NSMenuItem(title: localized("format.heading"), action: nil, keyEquivalent: "")
    headingItem.submenu = heading; menu.addItem(headingItem)
    add(menu, localized("format.paragraph"), "paragraph")
    group("format.list", [("format.bulletList", "bullet-list"), ("format.orderedList", "ordered-list"), ("format.taskList", "task-list"),
                          ("format.toggleTask", "toggle-task"), ("format.indent", "indent"), ("format.outdent", "outdent")])
    add(menu, localized("format.blockquote"), "blockquote")
    add(menu, localized("format.codeBlock"), "code-block")
    group("format.documentStructure", [("format.footnote", "insert-footnote"), ("format.gotoFootnote", "goto-footnote"), ("format.toc", "insert-toc"), ("format.metadata", "insert-frontmatter"), ("format.rule", "horizontal-rule")])
    menu.addItem(.separator())
    group("format.images", [("format.imageProperties", "image-properties"), ("format.imageImport", "image-import"), ("format.imagePaste", "image-paste"),
                            ("format.imageSmaller", "image-smaller"), ("format.imageLarger", "image-larger"), ("format.imageReset", "image-reset-size"),
                            ("format.imageReveal", "image-reveal"), ("format.imageCopy", "image-copy")])
    group("format.mathAndDiagram", [("format.mathInline", "math-inline"), ("format.mathBlock", "math-block"), ("format.diagram", "insert-diagram")])
    group("format.previewOptions", [
        ("format.previewSource", "preview-copy-source"), ("format.previewMathml", "preview-copy-mathml"), ("format.previewSvg", "preview-copy-svg"),
        ("format.saveSvg", "preview-save-svg"), ("format.previewRefresh", "preview-refresh"), ("format.previewCancel", "preview-cancel")
    ])
    let code = NSMenu(title: localized("format.codeOptions"))
    for (key, command) in [
        ("format.codeLanguage", "code-language"), ("format.codeIndent", "code-indent"),
        ("format.codeOutdent", "code-outdent"), ("format.codeCopy", "code-copy"),
        ("format.codeNumbers", "code-line-numbers"), ("format.codeWrap", "code-wrap")
    ] { add(code, localized(key), command) }
    let codeItem = NSMenuItem(title: localized("format.codeOptions"), action: nil, keyEquivalent: "")
    codeItem.submenu = code; menu.addItem(codeItem)
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
