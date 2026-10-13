import AppKit

extension EditorWindowController {
    func showComponentMenu(_ context: String, x: Double, y: Double) {
        guard documents.ready, isActiveDocument, x >= 0, y >= 0, x <= webView.bounds.width, y <= webView.bounds.height else { return }
        let commands: [String]
        switch context {
        case "image": commands = ["image-properties", "image-smaller", "image-larger", "image-reset-size", "image-copy", "image-reveal", "preview-refresh"]
        case "math": commands = ["preview-copy-source", "preview-copy-mathml", "preview-refresh", "preview-cancel"]
        case "diagram": commands = ["preview-copy-source", "preview-copy-svg", "preview-save-svg", "preview-refresh", "preview-cancel"]
        case "code": commands = ["code-language", "code-copy", "code-indent", "code-outdent", "code-line-numbers", "code-wrap"]
        case "table": commands = ["add-row", "add-column", "delete-row", "delete-column", "move-row-up", "move-row-down", "move-column-left", "move-column-right", "align-column-left", "align-column-center", "align-column-right", "delete-table"]
        default: return
        }
        let source = formattingMenu(target: self, action: #selector(formatAction(_:)))
        var indexed: [String: NSMenuItem] = [:]
        func collect(_ menu: NSMenu) {
            for item in menu.items {
                if let command = item.representedObject as? String { indexed[command] = item }
                if let submenu = item.submenu { collect(submenu) }
            }
        }
        collect(source)
        let menu = NSMenu()
        for command in commands {
            if let item = indexed[command]?.copy() as? NSMenuItem { menu.addItem(item) }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: webView.isFlipped ? y : webView.bounds.height - y), in: webView)
    }
}
