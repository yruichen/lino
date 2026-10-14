import AppKit

/// AppKit owns expansion, right anchoring and the single search glyph.
@MainActor
final class SearchToolbarItem: NSSearchToolbarItem {
    init() {
        super.init(itemIdentifier: NSToolbarItem.Identifier("editor-find"))
        let field = NSSearchField()
        field.font = .systemFont(ofSize: 13)
        field.sendsSearchStringImmediately = false; field.sendsWholeSearchString = true
        searchField = field; preferredWidthForSearchField = 260
        resignsFirstResponderWithCancel = false
    }
    required init(coder: NSCoder) { fatalError("Use init()") }
}
