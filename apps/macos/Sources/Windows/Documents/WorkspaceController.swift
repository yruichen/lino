import AppKit

private final class WorkspaceObserver: WorkspaceListener, @unchecked Sendable {
    private let callback: @Sendable () -> Void
    init(_ callback: @escaping @Sendable () -> Void) { self.callback = callback }
    func changed() { callback() }
}
/// Native presentation of the granted-root Rust service. Responses are accepted
/// only for the current root and query generation. No document content lives here.
@MainActor
final class WorkspaceController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    let view = NSStackView()
    private let roots = NSPopUpButton(frame: .zero, pullsDown: false)
    private let pin = NSButton()
    private let openFolder = NSButton()
    private let query = NSSearchField()
    private let mode = NSPopUpButton(frame: .zero, pullsDown: false)
    private let options = NSStackView()
    private let sensitive = NSButton(checkboxWithTitle: "Aa", target: nil, action: nil)
    private let regex = NSButton(checkboxWithTitle: ".*", target: nil, action: nil)
    private let word = NSButton(checkboxWithTitle: "↔", target: nil, action: nil)
    private let hidden = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let ordering = NSPopUpButton(frame: .zero, pullsDown: false)
    private let filters = NSButton()
    private var filtersVisible = false
    private let table = NSTableView()
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let breadcrumb = NSTextField(labelWithString: "")
    private let backend: DocumentBackend
    private let verifying: Bool
    private weak var window: NSWindow?
    private var service: WorkspaceService?
    private var rootPath: String?
    var currentRoot: String? { rootPath }
    private var directory = ""
    private var entries: [WorkspaceEntry] = []
    private var hits: [WorkspaceHit] = []
    private var searchResults = false
    private var generation: UInt64 = 0
    private var pending: Task<Void, Never>?
    private var running = false
    private var mutating = false { didSet { roots.isEnabled = !mutating } }
    private var observer: WorkspaceObserver?
    private var rootIdentity = UUID()
    private var watchUpdate: Task<Void, Never>?
    private var localizedButtons: [(NSButton, String)] = []
    private var localizedItems: [(NSMenuItem, String)] = []
    var onOpen: ((String, Int?) -> Void)?
    var onError: ((String) -> Void)?
    var onVisibility: ((Bool) -> Void)?

    init(backend: DocumentBackend, window: NSWindow, verifying: Bool = false) {
        self.backend = backend; self.window = window; self.verifying = verifying; super.init()
        view.orientation = .vertical; view.alignment = .leading; view.spacing = 10
        view.edgeInsets = NSEdgeInsets(top: 16, left: 12, bottom: 12, right: 12)
        roots.isBordered = false; roots.font = .systemFont(ofSize: 13, weight: .semibold)
        roots.target = self; roots.action = #selector(rootSelected)
        openFolder.target = self; openFolder.action = #selector(chooseFolder); openFolder.bezelStyle = .rounded
        pin.target = self; pin.action = #selector(togglePin); pin.bezelStyle = .inline; pin.imagePosition = .imageOnly
        query.delegate = self; query.controlSize = .regular; query.font = .systemFont(ofSize: 13)
        query.sendsSearchStringImmediately = true
        filters.target = self; filters.action = #selector(toggleFilters); filters.bezelStyle = .inline
        filters.image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: nil)
        mode.controlSize = .small; mode.isBordered = false; ordering.controlSize = .small
        for control in [mode, ordering] { control.target = self; control.action = #selector(refresh) }
        for button in [sensitive, regex, word, hidden] { button.target = self; button.action = #selector(refresh); button.controlSize = .small }
        options.orientation = .vertical; options.alignment = .leading; options.spacing = 8
        let searchOptions = NSStackView(views: [sensitive, regex, word]); searchOptions.spacing = 8
        options.setViews([searchOptions, hidden, ordering], in: .leading); options.isHidden = true
        let commands = NSStackView()
        for (key, symbol, selector) in [("workspace.up", "chevron.left", #selector(up)), ("workspace.refresh", "arrow.clockwise", #selector(refresh)), ("workspace.newFile", "square.and.pencil", #selector(newFile)), ("workspace.newFolder", "folder.badge.plus", #selector(newFolder))] {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: localized(key))!, target: self, action: selector)
            button.bezelStyle = .inline; commands.addArrangedSubview(button); localizedButtons.append((button, key))
        }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file")); column.width = 250
        table.addTableColumn(column); table.headerView = nil; table.delegate = self; table.dataSource = self
        table.style = .sourceList; table.backgroundColor = .clear; table.rowHeight = 34
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.target = self; table.doubleAction = #selector(openSelection)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        scroll.drawsBackground = false; scroll.autohidesScrollers = true
        let menu = NSMenu()
        for (key, selector) in [("workspace.open", #selector(openSelection)), ("workspace.copy", #selector(copyFile)), ("workspace.move", #selector(moveFile)), ("workspace.trash", #selector(trashFile)), ("workspace.reveal", #selector(revealFile)), ("workspace.properties", #selector(properties))] {
            let item = menu.addItem(withTitle: localized(key), action: selector, keyEquivalent: ""); item.target = self; localizedItems.append((item, key))
        }
        table.menu = menu
        notice.font = .systemFont(ofSize: 11); notice.textColor = .secondaryLabelColor
        breadcrumb.font = .systemFont(ofSize: 11); breadcrumb.textColor = .secondaryLabelColor; breadcrumb.lineBreakMode = .byTruncatingMiddle
        let rootRow = NSStackView(views: [roots, pin]); rootRow.alignment = .centerY; rootRow.spacing = 6
        roots.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let modeRow = NSStackView(views: [mode, NSView(), filters]); modeRow.alignment = .centerY
        let navigation = NSStackView(views: [breadcrumb, NSView(), commands]); navigation.alignment = .centerY
        breadcrumb.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        commands.spacing = 6
        for child in [rootRow, openFolder, query, modeRow, options, navigation, scroll, notice] {
            view.addArrangedSubview(child); child.translatesAutoresizingMaskIntoConstraints = false
            child.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -24).isActive = true
        }
        view.setVisibilityPriority(.notVisible, for: options)
        let scrollHeight = scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        scrollHeight.priority = .defaultLow; scrollHeight.isActive = true
        relocalize()
    }
    func relocalize() {
        let selectedMode = mode.indexOfSelectedItem, selectedOrder = ordering.indexOfSelectedItem
        mode.removeAllItems(); mode.addItems(withTitles: [localized("workspace.browse"), localized("workspace.quick"), localized("workspace.search")]); mode.selectItem(at: max(0, selectedMode))
        ordering.removeAllItems(); ordering.addItems(withTitles: [localized("workspace.byName"), localized("workspace.byDate")]); ordering.selectItem(at: max(0, selectedOrder))
        query.placeholderString = localized("workspace.query"); query.setAccessibilityLabel(localized("workspace.query"))
        sensitive.toolTip = localized("workspace.case"); regex.toolTip = localized("workspace.regex"); word.toolTip = localized("workspace.word"); hidden.title = localized("workspace.hidden")
        for (button, key) in localizedButtons { button.toolTip = localized(key); button.setAccessibilityLabel(localized(key)) }
        filters.toolTip = localized("workspace.filters"); filters.setAccessibilityLabel(localized("workspace.filters"))
        openFolder.title = localized("workspace.openFolder"); openFolder.setAccessibilityLabel(openFolder.title)
        for (item, key) in localizedItems { item.title = localized(key) }
        for (button, key) in [(sensitive, "workspace.case"), (regex, "workspace.regex"), (word, "workspace.word")] { button.setAccessibilityLabel(localized(key)) }
        updateRoots()
    }
    private func recentRoots() -> [String] { verifying ? [] : Array((UserDefaults.standard.stringArray(forKey: "workspaceRoots") ?? []).prefix(12)) }
    private func pinnedRoots() -> [String] { verifying ? [] : Array((UserDefaults.standard.stringArray(forKey: "pinnedWorkspaceRoots") ?? []).prefix(12)) }
    @objc private func togglePin() {
        guard !verifying, let path = rootPath else { return }
        let pinned = pinnedRoots()
        UserDefaults.standard.set(pinned.contains(path) ? pinned.filter { $0 != path } : Array(([path] + pinned).prefix(12)), forKey: "pinnedWorkspaceRoots")
        updateRoots()
    }
    private func updateRoots() {
        roots.removeAllItems(); roots.addItem(withTitle: rootPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? localized("workspace.noRoot"))
        let pinned = pinnedRoots()
        for path in pinned + recentRoots().filter({ !pinned.contains($0) }) where path != rootPath {
            roots.addItem(withTitle: (pinned.contains(path) ? "★ " : "") + path); roots.lastItem?.representedObject = path
        }
        let isPinned = rootPath.map { pinned.contains($0) } == true
        pin.image = NSImage(systemSymbolName: isPinned ? "pin.fill" : "pin", accessibilityDescription: nil)
        pin.toolTip = localized(isPinned ? "workspace.unpin" : "workspace.pin"); pin.setAccessibilityLabel(pin.toolTip)
        pin.isEnabled = rootPath != nil
        roots.addItem(withTitle: localized("workspace.openFolder")); roots.lastItem?.representedObject = "choose-root"
        roots.addItem(withTitle: localized("workspace.clearRecent")); roots.lastItem?.representedObject = "clear-recent"
    }
    func chooseRoot() async {
        guard !mutating else { notice.stringValue = localized("error.busy"); return }
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.title = localized("workspace.openFolder")
        guard await panel.beginSheetModal(for: window) == .OK, let path = panel.url?.path else { return }
        await openRoot(path)
    }
    @objc private func chooseFolder() { Task { await chooseRoot() } }
    func inheritRoot(_ path: String) async { await openRoot(path) }
    private func openRoot(_ path: String) async {
        invalidate(); let expected = generation
        do {
            let next = try await backend.perform { try $0.openWorkspace(path: path) }
            guard expected == generation else { return }
            let previous = service; service = next; rootPath = next.root(); directory = ""; query.stringValue = ""; mode.selectItem(at: 0)
            rootIdentity = UUID(); let identity = rootIdentity
            if let previous { Task.detached { previous.unwatch() } }
            observer = WorkspaceObserver { [weak self] in Task { @MainActor in self?.changedRoot(identity) } }
            if let observer {
                do { try await Task.detached { try next.watch(listener: observer) }.value }
                catch { fail(error) }
            }
            guard service === next else { return }
            entries = []; hits = []; searchResults = false; table.reloadData()
            let recents = [path] + recentRoots().filter { $0 != path }
            if !verifying { UserDefaults.standard.set(Array(recents.prefix(12)), forKey: "workspaceRoots") }
            updateRoots(); onVisibility?(true); refresh()
        } catch { if expected == generation { running = false; fail(error) } }
    }
    @objc private func rootSelected() {
        let selection = roots.selectedItem?.representedObject as? String
        if selection == "choose-root" { Task { await chooseRoot() } }
        else if selection == "clear-recent" { if !verifying { UserDefaults.standard.removeObject(forKey: "workspaceRoots") }; updateRoots() }
        else if let selection { Task { await openRoot(selection) } }
    }
    private func invalidate() {
        service?.cancel(queryId: generation); generation &+= 1; pending?.cancel(); pending = nil
    }
    @objc func refresh() {
        invalidate(); let expected = generation
        guard let service else { notice.stringValue = localized("workspace.noRoot"); return }
        let directory = self.directory, hidden = hidden.state == .on, text = query.stringValue
        let content = mode.indexOfSelectedItem == 2
        sensitive.isEnabled = content; regex.isEnabled = content; word.isEnabled = content
        let searching = mode.indexOfSelectedItem != 0 && !text.isEmpty
        let options = WorkspaceSearchOptions(text: text, content: content, caseSensitive: sensitive.state == .on, regex: regex.state == .on, wholeWord: word.state == .on, includeHidden: hidden)
        running = true; notice.stringValue = localized("workspace.loading")
        pending = Task { [weak self] in
            guard let self else { return }
            do {
                if searching {
                    let result = try await Task.detached(priority: .userInitiated) { try service.search(queryId: expected, options: options) }.value
                    guard !Task.isCancelled, expected == generation else { return }
                    searchResults = true; hits = result.hits
                    notice.stringValue = result.cancelled ? localized("workspace.cancelled") : localized(result.truncated ? "workspace.truncated" : "workspace.results", result.hits.count, result.skipped)
                } else {
                    let result = try await Task.detached(priority: .userInitiated) { try service.list(path: directory, hidden: hidden) }.value
                    guard !Task.isCancelled, expected == generation else { return }
                    searchResults = false; entries = result.entries.filter { text.isEmpty || $0.name.localizedCaseInsensitiveContains(text) }
                    if ordering.indexOfSelectedItem == 1 { entries.sort { $0.directory == $1.directory ? $0.modified > $1.modified : $0.directory } }
                    notice.stringValue = result.truncated ? localized("workspace.listTruncated") : localized("workspace.items", entries.count)
                }
                running = false; breadcrumb.stringValue = directory.isEmpty ? localized("workspace.browse") : directory
                breadcrumb.toolTip = directory.isEmpty ? rootPath : directory; table.reloadData()
            } catch { guard expected == generation else { return }; running = false; fail(error) }
        }
    }
    func controlTextDidChange(_ obj: Notification) {
        invalidate()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }; self?.refresh()
        }
    }
    func quickOpen() { onVisibility?(true); mode.selectItem(at: 1); window?.makeFirstResponder(query); refresh() }
    func searchWorkspace() { onVisibility?(true); mode.selectItem(at: 2); window?.makeFirstResponder(query); refresh() }
    func cancelSearch() { invalidate(); running = false; notice.stringValue = localized("workspace.cancelled") }
    @objc private func toggleFilters() {
        filtersVisible.toggle(); options.isHidden = !filtersVisible
        view.setVisibilityPriority(filtersVisible ? .mustHold : .notVisible, for: options)
        filters.state = filtersVisible ? .on : .off
    }
    private func changedRoot(_ identity: UUID) {
        guard identity == rootIdentity else { return }
        watchUpdate?.cancel()
        watchUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }; self?.refresh()
        }
    }
    func detach() {
        invalidate(); watchUpdate?.cancel(); rootIdentity = UUID(); observer = nil
        let previous = service; service = nil
        if let previous { Task.detached { previous.unwatch() } }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { searchResults ? hits.count : entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: WorkspaceRowView.reuseIdentifier, owner: self) as? WorkspaceRowView ?? WorkspaceRowView(frame: .zero)
        if searchResults { let hit = hits[row]; cell.configure(name: hit.path, directory: false, excerpt: "\(hit.line)  \(hit.preview)") }
        else { let entry = entries[row]; cell.configure(name: entry.name, directory: entry.directory) }
        return cell
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { searchResults ? 52 : 34 }
    private var selectedPath: String? {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < numberOfRows(in: table) else { return nil }
        return searchResults ? hits[row].path : entries[row].path
    }
    @objc private func openSelection() {
        guard let service, let path = selectedPath else { return }
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        if !searchResults && entries[row].directory { directory = path; query.stringValue = ""; mode.selectItem(at: 0); refresh(); return }
        let line = searchResults ? Int(hits[row].line) : nil
        Task {
            do {
                let fullPath = try await Task.detached { try service.resolve(path: path) }.value
                guard service === self.service else { return }; onOpen?(fullPath, line)
            } catch { if service === self.service { fail(error) } }
        }
    }
    @objc private func up() { directory = (directory as NSString).deletingLastPathComponent; query.stringValue = ""; refresh() }
    private func askPath(_ title: String, initial: String) async -> String? {
        guard let window else { return nil }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = localized("workspace.relativePath")
        let input = NSTextField(string: initial); input.frame.size = NSSize(width: 300, height: 24); alert.accessoryView = input
        alert.addButton(withTitle: localized("button.ok")); alert.addButton(withTitle: localized("button.cancel"))
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn ? input.stringValue : nil
    }
    private func mutate(_ operation: WorkspaceMutation, key: String) {
        guard let service, !mutating else { return }
        let source = selectedPath ?? ""
        let initial: String
        switch operation {
        case .newFile, .newDirectory: initial = directory.isEmpty ? "" : directory + "/"
        case .copy, .move: initial = source
        }
        Task {
            guard let target = await askPath(localized(key), initial: initial) else { return }
            guard service === self.service else { return }
            mutating = true; defer { mutating = false }
            do { try await Task.detached { try service.mutate(operation: operation, source: source, target: target) }.value; refresh() }
            catch { fail(error) }
        }
    }
    @objc private func newFile() { mutate(.newFile, key: "workspace.newFile") }
    @objc private func newFolder() { mutate(.newDirectory, key: "workspace.newFolder") }
    @objc private func copyFile() { mutate(.copy, key: "workspace.copy") }
    @objc private func moveFile() { mutate(.move, key: "workspace.move") }
    @objc private func trashFile() {
        guard let service, let path = selectedPath, let window, !mutating else { return }
        Task {
            let alert = NSAlert(); alert.messageText = localized("workspace.trashTitle", path); alert.informativeText = localized("workspace.trashDetail")
            alert.addButton(withTitle: localized("button.cancel")); alert.addButton(withTitle: localized("workspace.trash"))
            guard await alert.beginSheetModal(for: window) == .alertSecondButtonReturn, service === self.service else { return }
            mutating = true; defer { mutating = false }
            do { try await Task.detached { try service.trash(path: path) }.value; refresh() } catch { fail(error) }
        }
    }
    @objc private func revealFile() {
        guard let service, let path = selectedPath else { return }
        Task {
            do {
                let fullPath = try await Task.detached { try service.resolve(path: path) }.value
                guard service === self.service else { return }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: fullPath)])
            } catch { if service === self.service { fail(error) } }
        }
    }
    @objc private func properties() {
        guard let path = selectedPath, let window else { return }
        let alert = NSAlert(); alert.messageText = path
        if let entry = entries.first(where: { $0.path == path }) { alert.informativeText = localized("workspace.fileDetails", entry.bytes, Date(timeIntervalSince1970: TimeInterval(entry.modified)).description) }
        alert.addButton(withTitle: localized("button.ok")); Task { _ = await alert.beginSheetModal(for: window) }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool { selectedPath != nil && !mutating && !running }
    private func fail(_ error: Error) { notice.stringValue = error.localizedDescription; onError?(error.localizedDescription) }
}
