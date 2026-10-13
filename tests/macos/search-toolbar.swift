import AppKit

@main struct Checks {
    @MainActor static func main() {
        let controls = SearchToolbarView()
        var clicks = 0
        controls.onToggle = { clicks += 1; controls.setExpanded(!controls.expanded) }
        precondition(controls.field.isHidden && !controls.toggleButton.isHidden)
        precondition(controls.toggleButton.target === controls)
        controls.toggleButton.performClick(nil)
        precondition(clicks == 1 && controls.expanded && !controls.field.isHidden)
        precondition(controls.toggleButton.isTransparent && controls.toggleButton.image == nil)
        precondition(controls.field.focusRingType == .none)
        controls.frame.size = controls.fittingSize; controls.layoutSubtreeIfNeeded()
        let buttonRect = controls.toggleButton.frame
        precondition(buttonRect.width > 0 && buttonRect.height > 0)
        precondition(controls.hitTest(NSPoint(x: buttonRect.midX, y: buttonRect.midY)) === controls.toggleButton)
        precondition((controls.field.cell as? NSSearchFieldCell)?.cancelButtonCell != nil)
        let expandedWidth = controls.fittingSize.width
        controls.field.stringValue = "synthetic query"
        controls.toggleButton.performClick(nil)
        precondition(clicks == 2 && !controls.expanded && controls.field.isHidden)
        precondition(controls.field.stringValue == "synthetic query")
        precondition(controls.fittingSize.width < expandedWidth)
        controls.toggleButton.performClick(nil)
        precondition(clicks == 3 && controls.expanded && !controls.field.isHidden)
        print("Search toolbar: native button dispatch, expansion, collapse and query retention passed without a window.")
    }
}
