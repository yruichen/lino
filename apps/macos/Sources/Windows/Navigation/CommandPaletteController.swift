import AppKit

struct CommandPaletteEntry {
    let title: String
    let detail: String
    let keywords: String
    let enabled: Bool
    let action: () -> Void
}

struct CommandPaletteLabels {
    let placeholder: String
    let accessibility: String
    let results: String
    let keys: String
}

/// A searchable, keyboard-first command surface. Entries are rebuilt on every
/// presentation so menu state and document capabilities remain authoritative.
@MainActor
final class CommandPaletteController: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private weak var owner: NSWindow?
    private let panel = CommandPalettePanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    private let field = NSSearchField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let hint = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var height: NSLayoutConstraint!
    private var outsideMonitor: Any?
    private var deactivateObserver: NSObjectProtocol?
    private weak var previousResponder: NSResponder?
    private var entries: [CommandPaletteEntry] = []
    private var filtered: [CommandPaletteEntry] = []
    private(set) var visible = false

    override init() {
        super.init()
        field.delegate = self
        field.controlSize = .large
        field.placeholderString = ""
        field.setAccessibilityLabel("")
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .inset
        table.rowHeight = 44
        table.selectionHighlightStyle = .regular
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command")))
        table.dataSource = self; table.delegate = self; table.target = self; table.action = #selector(openSelected)
        table.setAccessibilityLabel("")
        scroll.documentView = table
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        hint.stringValue = ""
        let separator = NSBox(); separator.boxType = .separator
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        for view in [field, separator, scroll, hint] { stack.addArrangedSubview(view) }
        let material = NSVisualEffectView()
        material.material = .hudWindow; material.blendingMode = .withinWindow; material.state = .active
        material.wantsLayer = true; material.layer?.cornerRadius = 16; material.layer?.masksToBounds = true
        material.translatesAutoresizingMaskIntoConstraints = false; material.addSubview(stack); panel.contentView = material
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.isReleasedWhenClosed = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: material.topAnchor, constant: 15),
            stack.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -12),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hint.heightAnchor.constraint(equalToConstant: 18),
        ])
        height = scroll.heightAnchor.constraint(equalToConstant: 44 * 8); height.isActive = true
        deactivateObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    func relocalize(_ labels: CommandPaletteLabels) {
        field.placeholderString = labels.placeholder
        field.setAccessibilityLabel(labels.accessibility)
        hint.stringValue = labels.keys
        table.setAccessibilityLabel(labels.results)
    }

    func show(in window: NSWindow, entries: [CommandPaletteEntry], labels: CommandPaletteLabels) {
        dismiss()
        owner = window; previousResponder = window.firstResponder; self.entries = entries
        relocalize(labels)
        visible = true; field.stringValue = ""; refresh()
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(field)
        outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.window !== self?.panel { self?.dismiss() }
            }
            return event
        }
        resize()
    }

    func dismiss() {
        guard visible || panel.parent != nil else { return }
        panel.parent?.removeChildWindow(panel); panel.orderOut(nil)
        visible = false; entries.removeAll(); filtered.removeAll(); table.deselectAll(nil)
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
        owner?.makeKeyAndOrderFront(nil)
        if let previousResponder { owner?.makeFirstResponder(previousResponder) }
        previousResponder = nil; owner = nil
    }

    func detach() {
        dismiss()
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver); self.deactivateObserver = nil }
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1); return true
        case #selector(NSResponder.insertNewline(_:)): openSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        default: return false
        }
    }

    private func refresh() {
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        filtered = entries.filter(\.enabled).map { entry in
            (entry, score(entry, query: query))
        }.filter { query.isEmpty || $0.1 >= 0 }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.title.localizedCaseInsensitiveCompare($1.0.title) == .orderedAscending
        }.map(\.0)
        table.reloadData()
        if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        resize()
    }

    private func score(_ entry: CommandPaletteEntry, query: String) -> Int {
        guard !query.isEmpty else { return 0 }
        let haystack = "\(entry.title) \(entry.detail) \(entry.keywords)".lowercased()
        if haystack == query { return 1000 }
        if entry.title.lowercased().hasPrefix(query) { return 800 }
        if haystack.contains(query) { return 500 }
        var cursor = haystack.startIndex; var matched = 0
        for character in query {
            guard let index = haystack[cursor...].firstIndex(of: character) else { return -1 }
            matched += 1; cursor = haystack.index(after: index)
        }
        return matched == query.count ? 100 : -1
    }

    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let row = min(filtered.count - 1, max(0, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
    }

    @objc private func openSelected() {
        guard filtered.indices.contains(table.selectedRow) else { return }
        let action = filtered[table.selectedRow].action
        dismiss(); action()
    }

    private func resize() {
        guard let owner else { return }
        guard let guide = owner.contentLayoutGuide as? NSLayoutGuide else { return }
        let available = max(220, guide.frame.height - 160)
        height.constant = min(CGFloat(max(1, min(8, filtered.count))) * 44, available)
        let size = NSSize(width: min(620, max(360, guide.frame.width - 32)), height: stack.fittingSize.height + 27)
        panel.setContentSize(size)
        guard let content = owner.contentView else { return }
        let point = owner.convertPoint(toScreen: content.convert(NSPoint(x: guide.frame.midX, y: guide.frame.maxY - 12), to: nil))
        panel.setFrameOrigin(NSPoint(x: point.x - size.width / 2, y: point.y - size.height))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("command-row")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? CommandPaletteRow ?? CommandPaletteRow(frame: .zero)
        cell.identifier = identifier
        let entry = filtered[row]
        cell.configure(title: entry.title, detail: entry.detail)
        return cell
    }
}

@MainActor
private final class CommandPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CommandPaletteRow: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        detailLabel.font = .systemFont(ofSize: 11); detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 2
        stack.addArrangedSubview(titleLabel); stack.addArrangedSubview(detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    func configure(title: String, detail: String) { titleLabel.stringValue = title; detailLabel.stringValue = detail }
}
