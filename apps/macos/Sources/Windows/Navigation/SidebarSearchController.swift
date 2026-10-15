import AppKit

/// Content search stays in the current workspace's sidebar, independent of Quick Open.
@MainActor
final class SidebarSearchController: NSObject, NSSearchFieldDelegate, NSTableViewDelegate, NSTableViewDataSource {
    let view = NSStackView()
    let field = NSSearchField()
    private let table = NSTableView()
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let back = NSButton()
    private let navigation: NavigationCoordinator
    private var observer: UUID?
    private var hits: [WorkspaceHit] { navigation.contentSearch.hits }
    private var root: String? { navigation.contentSearch.root }
    var onClose: (() -> Void)?
    var onOpen: ((String, Int?) -> Void)?
    init(navigation: NavigationCoordinator) {
        self.navigation = navigation; super.init()
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        back.isBordered = false; back.target = self; back.action = #selector(close)
        field.delegate = self
        let header = NSStackView(views: [back, field]); header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 10, right: 12)
        table.headerView = nil; table.style = .sourceList; table.backgroundColor = .clear; table.rowHeight = 48
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content-hit")))
        table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(openSelected)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        notice.font = .systemFont(ofSize: 12); notice.textColor = .secondaryLabelColor
        view.orientation = .vertical; view.alignment = .leading; view.spacing = 8; view.distribution = .fill
        header.setContentHuggingPriority(.required, for: .vertical)
        notice.setContentHuggingPriority(.required, for: .vertical)
        scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        for child in [header, notice, scroll] {
            view.addArrangedSubview(child); child.translatesAutoresizingMaskIntoConstraints = false
            child.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        }
        observer = navigation.contentSearch.observe { [weak self] in self?.apply() }
        relocalize(); apply()
    }
    func relocalize() {
        field.placeholderString = localized("navigation.searchContents"); field.setAccessibilityLabel(field.placeholderString)
        back.toolTip = localized("navigation.backToBrowse"); back.setAccessibilityLabel(back.toolTip)
        table.setAccessibilityLabel(localized("navigation.contentResults"))
    }
    private func apply() {
        let owner = navigation.contentSearch
        if field.stringValue != owner.query { field.stringValue = owner.query }
        table.reloadData(); notice.stringValue = owner.notice
    }
    func show(root: String?, window: NSWindow?) {
        navigation.contentSearch.show(root: root); window?.makeFirstResponder(field)
    }
    func rebind(root: String?) { navigation.contentSearch.rebind(root: root) }
    func detach() { if let observer { navigation.contentSearch.removeObserver(observer); self.observer = nil } }
    @objc private func close() { navigation.contentSearch.close(); onClose?() }
    func controlTextDidChange(_ obj: Notification) { navigation.contentSearch.changeQuery(field.stringValue) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { openSelected(); return true }
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveUp(_:)) {
            guard !hits.isEmpty else { return true }
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = min(hits.count - 1, max(0, table.selectedRow + delta))
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row); return true
        }
        return false
    }
    @objc private func openSelected() {
        guard let root, hits.indices.contains(table.selectedRow) else { return }
        let hit = hits[table.selectedRow]; onOpen?((root as NSString).appendingPathComponent(hit.path), Int(hit.line))
    }
    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = WorkspaceRowView(frame: .zero), hit = hits[row]
        cell.configure(name: hit.path, directory: false, excerpt: "\(hit.line) · \(hit.preview)")
        return cell
    }
}
