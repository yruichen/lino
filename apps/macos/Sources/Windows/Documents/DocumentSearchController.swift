import AppKit

/// The native field projects the editor's query. CodeMirror remains the sole
/// owner of matches, options, navigation and replacement transactions.
@MainActor
final class DocumentSearchController: NSObject, NSSearchFieldDelegate {
    let item = NSToolbarItem(itemIdentifier: .editorFind)
    private let controls = SearchToolbarView()
    private var field: NSSearchField { controls.field }
    private let bridge: EditorBridge
    private var projection: [String: Any] = [:]
    private var changingInteraction = false
    private var querySequence: UInt64 = 0
    private var viewGeneration = -1
    var canSearch: (() -> Bool)?
    init(bridge: EditorBridge) {
        self.bridge = bridge; super.init()
        field.delegate = self; field.target = self; field.action = #selector(nextMatch)
        // The delegate forwards edits. The control action is a submission
        // (Return/search glyph), never an extra find-next on every keystroke.
        field.sendsSearchStringImmediately = false; field.sendsWholeSearchString = true
        item.view = controls; item.target = self; item.action = #selector(toggle); item.autovalidates = false
        item.isBordered = false
        controls.onToggle = { [weak self] in self?.toggle() }
        relocalize()
    }
    func relocalize() {
        item.label = localized("editor.find"); item.toolTip = localized("editor.findTip")
        field.placeholderString = localized("editor.find")
        field.setAccessibilityLabel(localized("editor.find"))
        updateToggleLabel()
    }
    private func updateToggleLabel() {
        let key = controls.expanded ? "editor.closeFind" : "editor.find"
        controls.toggleButton.toolTip = localized(controls.expanded ? key : "editor.findTip")
        controls.toggleButton.setAccessibilityLabel(localized(key))
    }
    func updateAvailability() {
        let available = canSearch?() == true
        item.isEnabled = available; field.isEnabled = available; controls.toggleButton.isEnabled = available
    }
    func apply(_ value: [String: Any]) {
        if viewGeneration != bridge.generation { reset(); viewGeneration = bridge.generation }
        projection = value
        let received = (value["querySequence"] as? String).flatMap(UInt64.init) ?? 0
        if received >= querySequence, let text = value["text"] as? String, field.stringValue != text, !isComposing {
            field.stringValue = text
        }
        changingInteraction = true; controls.setExpanded(value["open"] as? Bool == true); changingInteraction = false
        updateToggleLabel()
        updateAvailability()
    }
    func reset() { querySequence = 0; projection = [:]; field.stringValue = ""; endInteraction() }
    private var isComposing: Bool { (field.currentEditor() as? NSTextView)?.hasMarkedText() == true }
    func open(replacing: Bool = false) {
        guard canSearch?() == true else { return }
        changingInteraction = true
        controls.setExpanded(true, focus: true)
        updateToggleLabel()
        changingInteraction = false
        bridge.command(replacing ? "replace" : "find")
    }
    private func endInteraction() {
        changingInteraction = true
        controls.setExpanded(false)
        updateToggleLabel()
        changingInteraction = false
    }
    @objc func toggle() {
        guard !isComposing else { return }
        if controls.expanded { bridge.command("close-find"); endInteraction() }
        else { open() }
    }
    func controlTextDidBeginEditing(_ notification: Notification) {
        if !changingInteraction && projection["open"] as? Bool != true && canSearch?() == true { bridge.command("find") }
    }
    func controlTextDidChange(_ notification: Notification) {
        guard canSearch?() == true, !isComposing else { return }
        let text = field.stringValue
        guard let owner = bridge.sessionId else { return }
        let generation = bridge.generation
        guard querySequence < UInt64.max else { return }
        querySequence += 1; let sequence = String(querySequence)
        Task { [weak self] in
            do { _ = try await self?.bridge.call("searchInput", arguments: [text, sequence, owner, generation]) }
            catch { self?.bridge.onError?(error.localizedDescription) }
        }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) && !isComposing { bridge.command("close-find"); endInteraction(); return true }
        return false
    }
    @objc private func nextMatch() { if canSearch?() == true && !isComposing { bridge.command("find-next") } }
}
