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
    private var service: WorkspaceService?
    private var task: Task<Void, Never>?
    private var sequence: UInt64 = 0
    private var hits: [WorkspaceHit] = []
    private var root: String?
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
        relocalize()
    }
    func relocalize() {
        field.placeholderString = localized("navigation.searchContents"); field.setAccessibilityLabel(field.placeholderString)
        back.toolTip = localized("navigation.backToBrowse"); back.setAccessibilityLabel(back.toolTip)
        table.setAccessibilityLabel(localized("navigation.contentResults"))
    }
    func show(root: String?, window: NSWindow?) {
        self.root = root; field.stringValue = ""; hits = []; table.reloadData()
        notice.stringValue = localized(root == nil ? "navigation.chooseWorkspace" : "navigation.enterContentQuery")
        window?.makeFirstResponder(field)
    }
    func rebind(root: String?) { self.root = root; controlTextDidChange(Notification(name: NSControl.textDidChangeNotification)) }
    func cancel() { service?.cancel(queryId: sequence); sequence &+= 1; task?.cancel(); task = nil }
    @objc private func close() { cancel(); onClose?() }
    func controlTextDidChange(_ obj: Notification) {
        cancel(); let expected = sequence, query = field.stringValue
        guard let root, !query.isEmpty else { hits = []; table.reloadData(); notice.stringValue = localized(root == nil ? "navigation.chooseWorkspace" : "navigation.enterContentQuery"); return }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                let service = try await navigation.backend.perform { try $0.openWorkspace(path: root) }
                guard !Task.isCancelled, expected == sequence else { return }; self.service = service
                let options = WorkspaceSearchOptions(text: query, content: true, caseSensitive: false, regex: false, wholeWord: false, includeHidden: false)
                let result = try await Task.detached { try service.search(queryId: expected, options: options) }.value
                guard !Task.isCancelled, expected == sequence, !result.cancelled else { return }
                hits = result.hits; table.reloadData()
                notice.stringValue = result.truncated ? localized("navigation.partial") : hits.isEmpty ? localized("navigation.noResults") : ""
            } catch { guard !Task.isCancelled, expected == sequence else { return }; notice.stringValue = userFacingError(error) }
        }
    }
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
