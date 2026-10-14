import AppKit

struct QuickFile: Decodable, Sendable {
    let path: String
    let name: String
    let title: String
    let location: String
    var line: Int? = nil
    var preview: String? = nil
    private enum CodingKeys: String, CodingKey { case path, name, title, location }
}
struct QuickResults: Decodable, Sendable { let files: [QuickFile]; let truncated: Bool; let skipped: UInt64; let cancelled: Bool }

/// A transient control inside the document window. It never edits the document,
/// changes sidebar visibility or changes scope implicitly from a selected row.
@MainActor
final class QuickOpenController: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSPopoverDelegate {
    private weak var window: NSWindow?
    private let navigation: NavigationCoordinator
    private let popover = NSPopover()
    private let panel = NSView()
    private let stack = NSStackView()
    let field = NSSearchField()
    let table = NSTableView()
    private let scroll = NSScrollView()
    private let section = NSTextField(labelWithString: "")
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let scopeButton = NSButton(title: "", target: nil, action: nil)
    private let hints = NSTextField(labelWithString: "")
    private var height: NSLayoutConstraint!
    private(set) var results: [QuickFile] = []
    private var service: QuickOpenService?
    private var generation: UInt64 = 0
    private var pending: Task<Void, Never>?
    private weak var previousResponder: NSResponder?
    private var scope: String?
    private(set) var visible = false
    var currentWorkspace: (() -> String?)?
    var onOpenFolder: (() -> Void)?
    var currentFile: String?
    var onOpen: ((String, Int?) -> Void)?
    init(window: NSWindow, navigation: NavigationCoordinator) {
        self.window = window; self.navigation = navigation
        super.init()
        field.delegate = self; field.controlSize = .large
        table.headerView = nil; table.backgroundColor = .clear; table.style = .inset
        table.selectionHighlightStyle = .regular; table.rowHeight = 48
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("quick-file")))
        table.delegate = self; table.dataSource = self; table.target = self; table.action = #selector(openClicked)
        table.setAccessibilityLabel(localized("navigation.results"))
        scroll.documentView = table; scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        section.font = .systemFont(ofSize: 10, weight: .semibold); section.textColor = .secondaryLabelColor
        hints.font = .systemFont(ofSize: 11); hints.textColor = .secondaryLabelColor
        notice.font = .systemFont(ofSize: 12); notice.textColor = .secondaryLabelColor
        scopeButton.bezelStyle = .inline; scopeButton.target = self; scopeButton.action = #selector(clearScope)
        let header = NSStackView(views: [section, NSView(), scopeButton]); header.alignment = .centerY
        let separator = NSBox(); separator.boxType = .separator
        for child in [field, header, scroll, notice, separator, hints] { stack.addArrangedSubview(child) }
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        let controller = NSViewController(); controller.view = panel
        popover.contentViewController = controller; popover.behavior = .transient
        popover.animates = false; popover.delegate = self
        stack.translatesAutoresizingMaskIntoConstraints = false; panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 15),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -12),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            notice.widthAnchor.constraint(equalTo: stack.widthAnchor), separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        height = scroll.heightAnchor.constraint(equalToConstant: 48 * 8); height.isActive = true
        relocalize()
    }
    func show() {
        guard let window, let container = window.contentView else { return }
        if visible { dismiss() }
        previousResponder = window.firstResponder
        scope = currentWorkspace?()
        field.stringValue = ""; results = []; visible = true; notice.isHidden = true
        resize(); relocalize()
        let guide = window.contentLayoutGuide as! NSLayoutGuide
        let anchor = NSRect(x: guide.frame.midX - 1, y: guide.frame.maxY - 12, width: 2, height: 1)
        popover.show(relativeTo: anchor, of: container, preferredEdge: .minY)
        field.window?.makeFirstResponder(field)
        refreshSearch()
    }
    func resize() {
        let guide = window?.contentLayoutGuide as? NSLayoutGuide
        let available = (guide?.frame.height ?? 420) - 190
        height.constant = min(CGFloat(min(8, max(1, results.count))) * 48, max(48, available))
        popover.contentSize = NSSize(width: min(560, max(280, (guide?.frame.width ?? 592) - 32)), height: stack.fittingSize.height + 27)
    }
    func dismiss() {
        if popover.isShown { popover.performClose(nil) }
        endPresentation()
    }
    func popoverDidClose(_ notification: Notification) { endPresentation() }
    private func endPresentation() {
        guard visible else { return }
        visible = false; cancel()
        if let previousResponder { window?.makeFirstResponder(previousResponder) }
        previousResponder = nil
    }
    func relocalize() {
        field.placeholderString = localized("navigation.searchFiles")
        field.setAccessibilityLabel(field.placeholderString)
        section.stringValue = localized(field.stringValue.isEmpty ? "navigation.recent" : "navigation.files")
        scopeButton.title = scope.map { URL(fileURLWithPath: $0).lastPathComponent } ?? localized("navigation.addFolder")
        scopeButton.isEnabled = scope == nil; scopeButton.toolTip = scope
        scopeButton.setAccessibilityLabel(scopeButton.title)
        hints.stringValue = localized("navigation.keys")
        if visible { table.reloadData() }
    }
    @objc private func clearScope() { dismiss(); onOpenFolder?() }
    private func cancel() {
        service?.cancel(queryId: generation)
        generation &+= 1; pending?.cancel(); pending = nil
    }
    @objc func refreshSearch() {
        cancel(); guard visible else { return }
        let expected = generation, text = field.stringValue, scope = self.scope, current = currentFile
        notice.isHidden = true; relocalize()
        pending = Task { [weak self] in
            guard let self else { return }
            if !text.isEmpty {
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled else { return }
            }
            do {
                if service == nil { service = try await navigation.backend.perform { $0.quickOpenService() } }
                guard let service, !Task.isCancelled, expected == generation else { return }
                let json = try await Task.detached(priority: .userInitiated) { try service.search(queryId: expected, text: text, scope: scope, current: current) }.value
                let result = try JSONDecoder().decode(QuickResults.self, from: Data(json.utf8))
                guard !Task.isCancelled, expected == generation, visible, !result.cancelled else { return }
                results = Array(result.files.prefix(8))
                table.reloadData()
                if !results.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
                notice.stringValue = result.truncated ? localized("navigation.partial") : result.skipped > 0 ? localized("navigation.skipped", result.skipped) : results.isEmpty ? localized(text.isEmpty ? "navigation.noRecent" : "navigation.noResults") : ""
                notice.isHidden = notice.stringValue.isEmpty; resize()
            } catch {
                guard !Task.isCancelled, expected == generation, visible else { return }
                results = []; table.reloadData(); notice.isHidden = false
                notice.stringValue = userFacingError(error); resize()
            }
        }
    }
    func controlTextDidChange(_ obj: Notification) { refreshSearch() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1); return true
        case #selector(NSResponder.insertNewline(_:)): openRow(table.selectedRow); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        default: return false
        }
    }
    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let row = min(results.count - 1, max(0, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
    }
    @objc private func openClicked() { openRow(table.clickedRow) }
    private func openRow(_ row: Int) {
        guard results.indices.contains(row) else { return }
        let file = results[row]; dismiss(); onOpen?(file.path, file.line)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: WorkspaceRowView.reuseIdentifier, owner: self) as? WorkspaceRowView ?? WorkspaceRowView(frame: .zero)
        let file = results[row]
        let parent: String
        if !file.location.isEmpty && file.path.hasPrefix(file.location + "/") {
            let relative = String(file.path.dropFirst(file.location.count + 1))
            let directory = (relative as NSString).deletingLastPathComponent
            parent = URL(fileURLWithPath: file.location).lastPathComponent + (directory.isEmpty ? "" : " / " + directory)
        } else { parent = (file.path as NSString).deletingLastPathComponent }
        let detail = file.preview.map { "\(file.line ?? 1) · \($0)" } ?? parent
        cell.configure(name: file.name, directory: false, excerpt: detail); cell.toolTip = file.path
        return cell
    }
    func detach() { dismiss(); cancel(); service = nil }
}
