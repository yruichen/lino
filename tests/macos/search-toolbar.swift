import AppKit

@main struct Checks {
    @MainActor static func main() {
        let item = SearchToolbarItem()
        precondition(item.preferredWidthForSearchField == 260)
        precondition(!item.resignsFirstResponderWithCancel)
        precondition(item.searchField.focusRingType == .none)
        precondition((item.searchField.cell as? NSSearchFieldCell)?.cancelButtonCell != nil)
        item.searchField.stringValue = "synthetic query"
        item.beginSearchInteraction(); item.endSearchInteraction()
        precondition(item.searchField.stringValue == "synthetic query")
        print("Native search item preserves queries and keeps clear separate from closing.")
    }
}
