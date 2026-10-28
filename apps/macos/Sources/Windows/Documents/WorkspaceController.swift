import AppKit

// This controller intentionally owns the native sidebar presentation, outline,
// search bridge and file mutations as one lifecycle-bound coordinator; the
// suppression keeps its lifecycle boundary visible without hiding member checks.
// swiftlint:disable type_body_length

/// Native navigation presentation. Directory and mutation semantics stay in Rust;
/// sidebar presentation is shared; headings belong to the active document.
@MainActor
final class WorkspaceController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let view = NSStackView()
    private weak var window: NSWindow?
    private let navigation: NavigationCoordinator
    private let verifying: Bool
    let outline = NavigationOutlineView()
    let scroll = NSScrollView()
    private let navigationContent = NSView()
    private let switcher = NSSegmentedControl()
    private let locationPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let searchButton = NSButton()
    private var selectedRoot: String?
    private var searching = false
    private var browseOrigin = NSPoint.zero
    private var pageOrigins: [Bool: NSPoint] = [:]
    private var browsingOutline = false
    private var scrollObserver: NSObjectProtocol?
    private let pages = NSStackView()
    private lazy var contentSearch = SidebarSearchController(navigation: navigation)
    private let addButton = NSButton()
    private let customizeButton = NSButton()
    private let continueButton = NSButton()
    var onContinueOutline: (() -> Void)?
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let outlineEmpty = NSTextField(wrappingLabelWithString: "")
    private var headingNoticeKey: String?
    private var headingsExhausted = false
    private let empty = NSStackView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let openButton = NSButton()
    private var items: [NavigationItem] = []
    private var nodes: [String: NavigationItem] = [:]
    private var headings: [NavigationHeading] = []
    private var headingToken = ""
    private var headingCurrent: Int?
    private var observer: UUID?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var auxiliaryServices: [String: WorkspaceService] = [:]
    private var contextItem: NavigationItem?
    private var searchObserver: UUID?
    private var presentationObserver: UUID?
    private var applyingPresentation = false
    private var lastPresentation = SidebarPresentation.Values()
    private var disposed = false
    private var rebuilding = false
    private var applyingExpansion = false
    private var expanded = Set<String>()
    private var collapsedHeadings = Set<String>()
    private var collapsedSections = Set<String>()
    private var selectedID: String?
    private var renderedPreferences: NavigationPreferences?
    private var renderedOpenFiles: [String] = []
    private var renderedRecents: [String] = []
    private let dragType = NSPasteboard.PasteboardType("dev.lino.navigation-item")
    private(set) var currentFile: String?
    private(set) var showingOutline = false
    var currentRoot: String? {
        if let selectedRoot, navigation.values.locations.contains(selectedRoot) { return selectedRoot }
        return navigation.values.locations.first
    }
    var onOpen: ((String, Int?) -> Void)?
    var onOpenDialog: (() -> Void)?
    var onError: ((String) -> Void)?
    var onVisibility: ((Bool) -> Void)?
    var onOutlineVisibility: ((Bool) -> Void)?
    var onHeading: ((Int, String) -> Void)?
    var onQuickOpen: (() -> Void)?
    var onContentSearch: (() -> Void)?
    var onCustomize: (() -> Void)?
    init(navigation: NavigationCoordinator, window: NSWindow, verifying: Bool) {
        self.navigation = navigation; self.window = window; self.verifying = verifying
        super.init()
        switcher.segmentCount = 2; switcher.segmentStyle = .rounded; switcher.trackingMode = .selectOne
        switcher.segmentDistribution = .fillEqually
        switcher.selectedSegment = 0; switcher.target = self; switcher.action = #selector(switchSection)
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.bezelStyle = .accessoryBarAction; addButton.isBordered = false; addButton.target = self; addButton.action = #selector(addContextFile)
        customizeButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        customizeButton.bezelStyle = .accessoryBarAction; customizeButton.isBordered = false
        customizeButton.target = self; customizeButton.action = #selector(customize)
        locationPicker.isBordered = false; locationPicker.font = .systemFont(ofSize: 13, weight: .medium)
        locationPicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        locationPicker.target = self; locationPicker.action = #selector(changeLocation)
        searchButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchButton.isBordered = false; searchButton.target = self; searchButton.action = #selector(searchContents)
        let header = NSStackView(views: [locationPicker, NSView(), searchButton, addButton, customizeButton]); header.spacing = 5
        header.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 8, right: 10)
        pages.addArrangedSubview(switcher); pages.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 10, right: 12)
        switcher.translatesAutoresizingMaskIntoConstraints = false
        switcher.widthAnchor.constraint(equalTo: pages.widthAnchor, constant: -24).isActive = true
        outline.headerView = nil; outline.style = .sourceList; outline.backgroundColor = .clear
        outline.indentationPerLevel = 12; outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("navigation")); outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.dataSource = self; outline.delegate = self; outline.target = self; outline.action = #selector(clicked)
        outline.onOpen = { [weak self] in self?.openSelection() }
        outline.onDoubleClick = { [weak self] row in self?.openSelection(row: row) }
        outline.registerForDraggedTypes([dragType, .fileURL]); outline.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        let menu = NSMenu(); menu.delegate = self; outline.menu = menu
        scroll.documentView = outline; scroll.hasVerticalScroller = true; scroll.drawsBackground = true
        scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        scroll.contentView.drawsBackground = false
        scroll.backgroundColor = ThemePalette.navigationBackground
        outline.backgroundColor = ThemePalette.navigationBackground
        outlineEmpty.identifier = NSUserInterfaceItemIdentifier("outline-empty")
        outlineEmpty.font = .systemFont(ofSize: 13); outlineEmpty.textColor = .secondaryLabelColor
        outlineEmpty.alignment = .center; outlineEmpty.isHidden = true
        for subview in [scroll, outlineEmpty] { subview.translatesAutoresizingMaskIntoConstraints = false; navigationContent.addSubview(subview) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: navigationContent.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: navigationContent.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: navigationContent.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: navigationContent.bottomAnchor),
            outlineEmpty.centerXAnchor.constraint(equalTo: navigationContent.centerXAnchor),
            outlineEmpty.centerYAnchor.constraint(equalTo: navigationContent.centerYAnchor),
            outlineEmpty.leadingAnchor.constraint(greaterThanOrEqualTo: navigationContent.leadingAnchor, constant: 20),
            outlineEmpty.trailingAnchor.constraint(lessThanOrEqualTo: navigationContent.trailingAnchor, constant: -20),
        ])
        notice.font = .systemFont(ofSize: 11); notice.textColor = .secondaryLabelColor
        notice.isHidden = true
        openButton.bezelStyle = .rounded; openButton.target = self; openButton.action = #selector(openDocument)
        let addEmpty = NSButton(title: "", target: self, action: #selector(chooseFolder)); addEmpty.identifier = NSUserInterfaceItemIdentifier("add-folder"); addEmpty.bezelStyle = .rounded
        empty.orientation = .vertical; empty.alignment = .centerX; empty.spacing = 12
        empty.edgeInsets = NSEdgeInsets(top: 24, left: 16, bottom: 24, right: 16)
        empty.addArrangedSubview(emptyLabel); empty.addArrangedSubview(openButton); empty.addArrangedSubview(addEmpty)
        emptyLabel.alignment = .center; emptyLabel.textColor = .secondaryLabelColor
        view.orientation = .vertical; view.alignment = .leading; view.spacing = 0; view.distribution = .fill
        header.setContentHuggingPriority(.required, for: .vertical)
        pages.setContentHuggingPriority(.required, for: .vertical)
        navigationContent.setContentHuggingPriority(.defaultLow, for: .vertical)
        contentSearch.view.setContentHuggingPriority(.defaultLow, for: .vertical)
        continueButton.target = self; continueButton.action = #selector(continueOutline); continueButton.bezelStyle = .inline; continueButton.isHidden = true
        for subview in [header, pages, empty, navigationContent, notice, continueButton] {
            view.addArrangedSubview(subview); subview.translatesAutoresizingMaskIntoConstraints = false
            subview.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        }
        notice.setContentHuggingPriority(.required, for: .vertical)
        contentSearch.view.isHidden = true
        view.addArrangedSubview(contentSearch.view); contentSearch.view.translatesAutoresizingMaskIntoConstraints = false
        contentSearch.view.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        contentSearch.onOpen = { [weak self] path, line in self?.onOpen?(path, line) }
        contentSearch.onClose = { [weak self] in self?.hideContentSearch() }
        observer = navigation.observe { [weak self] root in self?.navigationChanged(root) }
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.applyingPresentation, !self.rebuilding, !self.searching else { return }
                self.browsingOutline = true
                self.pageOrigins[self.showingOutline] = self.scroll.contentView.bounds.origin; self.saveWindowState(persist: false)
            }
        }
        searchObserver = navigation.contentSearch.observe { [weak self] in
            guard let self, searching != navigation.contentSearch.active else { return }
            if navigation.contentSearch.active { presentContentSearch() } else { hideContentSearch() }
        }
        applyPresentation(navigation.sidebar.values)
        presentationObserver = navigation.sidebar.observe { [weak self] value in self?.applyPresentation(value) }
        if navigation.contentSearch.active { presentContentSearch() }
        relocalize(); rebuild()
    }
    private func applyPresentation(_ value: SidebarPresentation.Values) {
        guard value != lastPresentation else { return }
        let structureChanged = selectedRoot != value.workspace || expanded != value.expanded || collapsedSections != value.collapsedSections || showingOutline != value.outline
        let changedPage = showingOutline != value.outline
        applyingPresentation = true
        selectedRoot = value.workspace; expanded = value.expanded; collapsedSections = value.collapsedSections
        showingOutline = value.outline
        pageOrigins[false] = NSPoint(x: value.filesX, y: value.filesY)
        pageOrigins[true] = NSPoint(x: value.outlineX, y: value.outlineY)
        lastPresentation = value
        if structureChanged { rebuild(); if searching { contentSearch.rebind(root: currentRoot) } }
        switcher.selectedSegment = value.outline ? 1 : 0
        if changedPage { onOutlineVisibility?(showingOutline) }
        if !searching {
            scroll.contentView.scroll(to: pageOrigins[showingOutline] ?? .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        applyingPresentation = false
    }
    private func saveWindowState(persist: Bool = true) {
        guard !applyingPresentation else { return }
        navigation.sidebar.change(persist: persist) {
            $0.workspace = selectedRoot; $0.expanded = expanded; $0.collapsedSections = collapsedSections; $0.outline = showingOutline
            if let origin = pageOrigins[false] { $0.filesX = origin.x; $0.filesY = origin.y }
            if let origin = pageOrigins[true] { $0.outlineX = origin.x; $0.outlineY = origin.y }
        }
    }
    func relocalize() {
        switcher.setLabel(localized("navigation.files"), forSegment: 0); switcher.setLabel(localized("writing.outline"), forSegment: 1)
        switcher.setAccessibilityLabel(localized("navigation.section"))
        searchButton.toolTip = localized("workspace.searchContents"); searchButton.setAccessibilityLabel(searchButton.toolTip)
        addButton.toolTip = localized(currentRoot == nil ? "navigation.addFolder" : "workspace.newFile"); addButton.setAccessibilityLabel(addButton.toolTip)
        customizeButton.toolTip = localized("navigation.customize"); customizeButton.setAccessibilityLabel(customizeButton.toolTip)
        emptyLabel.stringValue = localized("navigation.empty")
        outlineEmpty.stringValue = localized("analysis.empty")
        openButton.title = localized("menu.open")
        (empty.arrangedSubviews.last as? NSButton)?.title = localized("navigation.addFolder")
        outline.setAccessibilityLabel(localized(showingOutline ? "writing.outline" : "navigation.files"))
        contentSearch.relocalize(); rebuild()
    }
    func chooseRoot() async {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.title = localized("navigation.addFolder"); panel.prompt = localized("navigation.add")
        guard await panel.beginSheetModal(for: window) == .OK else { return }
        for url in panel.urls { if let root = await navigation.addLocation(url.path) { selectedRoot = root } }
        saveWindowState(); rebuild()
        if searching { contentSearch.rebind(root: currentRoot) }
        onVisibility?(true)
    }
    @objc private func searchContents() { onContentSearch?() }
    @objc private func addContextFile() {
        guard let root = currentRoot else { chooseFolder(); return }
        contextItem = fileNode(root, prefix: "location", directory: true); newFile()
    }
    @objc private func changeLocation() {
        if locationPicker.indexOfSelectedItem >= navigation.values.locations.count { chooseFolder(); return }
        selectedRoot = navigation.values.locations[locationPicker.indexOfSelectedItem]; saveWindowState(); rebuild()
        if searching { contentSearch.rebind(root: currentRoot) }
    }
    @objc private func chooseFolder() { Task { await chooseRoot() } }
    @objc private func openDocument() { onOpenDialog?() }
    @objc private func customize() {
        let menu = NSMenu()
        func action(_ key: String, _ selector: Selector) { let item = menu.addItem(withTitle: localized(key), action: selector, keyEquivalent: ""); item.target = self }
        action("navigation.addFolder", #selector(chooseFolder))
        if let root = currentRoot {
            contextItem = fileNode(root, prefix: "location", directory: true)
            action("workspace.reveal", #selector(revealFile)); action("navigation.removeLocation", #selector(removeLocation))
        }
        menu.addItem(.separator()); action("navigation.customize", #selector(showCustomization))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: customizeButton.bounds.minY - 4), in: customizeButton)
    }
    @objc private func showCustomization() { onCustomize?() }
    @objc private func switchSection() { setOutline(switcher.selectedSegment == 1) }
    func setOutline(_ value: Bool) {
        guard value != showingOutline else { return }
        pageOrigins[showingOutline] = scroll.contentView.bounds.origin
        showingOutline = value; browsingOutline = false
        // Publish and perform native layout only after the outline's cached
        // rows match its new data source, including a zero-heading page.
        rebuild(); switcher.selectedSegment = value ? 1 : 0
        onOutlineVisibility?(value); saveWindowState()
        scroll.contentView.scroll(to: pageOrigins[value] ?? .zero); scroll.reflectScrolledClipView(scroll.contentView)
    }
    func setCurrentFile(_ path: String?) {
        guard currentFile != path else { return }
        currentFile = path; rebuild(); followCurrentFile()
    }
    private func followCurrentFile() {
        if navigation.values.follow_active, !showingOutline, let path = currentFile {
            // Follow only already-visible rows; never reopen a deliberately collapsed tree.
            if let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? NavigationItem)?.path == path }) {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                let visible = outline.rows(in: outline.visibleRect)
                if visible.location != NSNotFound && row >= visible.location - 3 && row <= NSMaxRange(visible) + 3 { outline.scrollRowToVisible(row) }
            }
        }
    }
    func applyHeadings(_ projection: [String: Any]) {
        guard let token = projection["token"] as? String else { return }
        let entries = projection["entries"] as? [[String: Any]] ?? []
        let changed = token != headingToken
        let previousCurrent = headingCurrent
        headingToken = token; headingCurrent = projection["current"] as? Int
        headingNoticeKey = projection["truncated"] as? Bool == true ? "navigation.headingLimit"
            : projection["exhausted"] as? Bool == true ? "navigation.headingPartial"
            : projection["complete"] as? Bool == false ? "analysis.parsing" : nil
        headingsExhausted = projection["exhausted"] as? Bool == true
        var structureChanged = false
        if changed {
            var existing: [String: NavigationHeading] = [:]
            func collect(_ list: [NavigationHeading]) { for heading in list { existing[heading.id] = heading; collect(heading.children) } }
            collect(headings)
            var parents: [NavigationHeading] = [], next: [NavigationHeading] = []
            var relationships: [String: [String]] = [:], oldRelationships: [String: [String]] = ["root": headings.map(\.id)]
            for heading in existing.values { oldRelationships[heading.id] = heading.children.map(\.id) }
            var live = Set<String>()
            for entry in entries {
                guard let id = entry["id"] as? String, let from = entry["from"] as? Int, let level = entry["level"] as? Int, let title = entry["title"] as? String else { continue }
                let item = existing[id] ?? NavigationHeading(id: id, from: from, title: title, level: level)
                if item.title != title || item.level != level { structureChanged = true }
                item.from = from; item.title = title; item.level = level; item.children = []; live.insert(id)
                while let last = parents.last, last.level >= level { parents.removeLast() }
                if let parent = parents.last { parent.children.append(item); relationships[parent.id, default: []].append(id) }
                else { next.append(item); relationships["root", default: []].append(id) }
                parents.append(item)
            }
            for id in live { relationships[id] = relationships[id] ?? [] }
            structureChanged = structureChanged || relationships != oldRelationships
            headings = next; collapsedHeadings.formIntersection(live)
        }
        if showingOutline && !searching {
            if structureChanged {
                let origin = scroll.contentView.bounds.origin
                applyingExpansion = true; outline.reloadData(); restoreHeadingExpansion(); applyingExpansion = false
                scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
            }
            if let current = headingCurrent, let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? NavigationHeading)?.from == current }) {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                let visible = outline.rows(in: outline.visibleRect)
                if !changed, previousCurrent != current, !browsingOutline, visible.location != NSNotFound,
                   (row < visible.location || row >= NSMaxRange(visible)) { outline.scrollRowToVisible(row) }
            } else { outline.deselectAll(nil) }
            updateHeadingStatus()
        }
    }
    private func updateHeadingStatus() {
        outlineEmpty.isHidden = !showingOutline || searching || !headings.isEmpty || headingNoticeKey != nil
        guard showingOutline, !searching else { return }
        notice.stringValue = headingNoticeKey.map { localized($0) } ?? ""
        notice.isHidden = notice.stringValue.isEmpty
        continueButton.isHidden = !headingsExhausted
        continueButton.title = localized("navigation.loadHeadings")
    }
    @objc private func continueOutline() { onContinueOutline?() }
    private func navigationChanged(_ root: String?) {
        // Removing a location revokes its pending listing even when the update
        // is a configuration publication rather than a directory invalidation.
        let roots = Set(navigation.values.locations + navigation.values.favorites)
        for id in Array(tasks.keys) {
            if let node = nodes[id], let owner = node.root, !roots.contains(owner) {
                tasks.removeValue(forKey: id)?.cancel(); node.loading = false; node.loaded = false
            }
        }
        if let root {
            let invalidated = nodes.values.filter { $0.section == nil && (root.isEmpty || $0.root == root) }
            for node in invalidated {
                tasks.removeValue(forKey: node.id)?.cancel()
                // A watcher invalidates knowledge of directory membership, not
                // the last complete presentation. Keep that list until the
                // replacement has arrived, including during atomic saves.
                node.loaded = false; node.loading = false
            }
            if !showingOutline {
                for node in invalidated where node.directory {
                    let hiddenRoot = !navigation.values.show_root && node.id == "location:" + (currentRoot ?? "")
                    if hiddenRoot || outline.isItemExpanded(node) { load(node) }
                }
            }
            return
        }
        let values = navigation.values
        let followingEnabled = renderedPreferences?.follow_active != true && values.follow_active
        guard renderedPreferences != values
            || values.show_open_files && renderedOpenFiles != navigation.openFiles
            || values.show_recents && renderedRecents != navigation.recent else { return }
        rebuild()
        if followingEnabled { followCurrentFile() }
    }
    private func node(_ id: String, title: String) -> NavigationItem {
        if let item = nodes[id] { item.title = title; return item }
        let item = NavigationItem(id: id, title: title); nodes[id] = item; return item
    }
    private func fileNode(_ path: String, prefix: String, directory: Bool = false) -> NavigationItem {
        let title = URL(fileURLWithPath: path).lastPathComponent
        let item = node(prefix + ":" + path, title: title); item.path = path; item.directory = directory
        if let root = navigation.values.locations.filter({ path == $0 || path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
            item.root = root; item.relative = path == root ? "" : String(path.dropFirst(root.count + 1))
        } else if directory { item.root = path; item.relative = "" }
        else { item.root = (path as NSString).deletingLastPathComponent; item.relative = URL(fileURLWithPath: path).lastPathComponent }
        return item
    }
    private func rebuild() {
        guard !disposed, !rebuilding else { return }; rebuilding = true; defer { rebuilding = false }
        let scrollOrigin = scroll.contentView.bounds.origin
        let values = navigation.values
        if renderedPreferences?.sort != values.sort {
            // Sorting is a presentation of cached directory entries. Changing
            // the setting must take effect without waiting for another I/O.
            for item in nodes.values where item.section == nil && item.directory {
                item.children = sortedChildren(item.children)
            }
        }
        renderedPreferences = values; renderedOpenFiles = navigation.openFiles; renderedRecents = navigation.recent
        if !showingOutline {
            var sections: [String: [NavigationItem]] = [:]
            sections["favorites"] = values.show_favorites ? values.favorites.map { path in
                // Stored favorites are shortcuts; directory identity is refreshed by the service.
                fileNode(path, prefix: "favorite", directory: navigation.services[path] != nil || auxiliaryServices[path] != nil)
            } : []
            var locations = currentRoot.map { [fileNode($0, prefix: "location", directory: true)] } ?? []
            if !values.show_root, let root = locations.first {
                if !root.loaded { load(root) }; locations = root.children
            }
            sections["locations"] = values.show_locations ? locations : []
            sections["open_files"] = values.show_open_files
                ? navigation.openFiles.filter { path in !values.locations.contains { path == $0 || path.hasPrefix($0 + "/") } }.map { fileNode($0, prefix: "open") }
                : []
            sections["recents"] = values.show_recents ? navigation.recent.prefix(20).map { fileNode($0, prefix: "recent") } : []
            items = values.sections.compactMap { key in
                guard let children = sections[key], !children.isEmpty || key == "locations" && !values.locations.isEmpty && values.show_locations else { return nil }
                let group = node("section:" + key, title: localized("navigation." + key)); group.section = key; group.children = children; group.loaded = true
                if key == "locations", !values.show_root, let path = currentRoot { group.path = path; group.root = path; group.directory = true }
                else { group.path = nil; group.root = nil; group.directory = false }
                return group
            }
        }
        // The data-source projection above is pure Swift. Commit its row cache
        // before AppKit setters can synchronously lay out a floating group row.
        applyingExpansion = true
        outline.reloadData()
        if showingOutline { restoreHeadingExpansion() }
        else {
            for item in items where item.section != nil && !collapsedSections.contains(item.id) { outline.expandItem(item) }
            for id in expanded { if let item = nodes[id] { outline.expandItem(item) } }
            if let selectedID, let item = nodes[selectedID], outline.row(forItem: item) >= 0 { outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: item)), byExtendingSelection: false) }
        }
        applyingExpansion = false
        outline.selectionHighlightStyle = .regular
        outline.rowHeight = showingOutline ? 29 : values.compact ? 24 : 29
        locationPicker.removeAllItems()
        for root in values.locations { locationPicker.addItem(withTitle: URL(fileURLWithPath: root).lastPathComponent); locationPicker.lastItem?.toolTip = root }
        locationPicker.addItem(withTitle: localized("navigation.addFolder"))
        if let root = currentRoot, let index = values.locations.firstIndex(of: root) { locationPicker.selectItem(at: index) }
        searchButton.isEnabled = currentRoot != nil
        if !showingOutline { continueButton.isHidden = true; notice.isHidden = true }
        empty.isHidden = showingOutline || !items.isEmpty || searching
        navigationContent.isHidden = (!showingOutline && items.isEmpty) || searching
        updateHeadingStatus()
        scroll.contentView.scroll(to: scrollOrigin); scroll.reflectScrolledClipView(scroll.contentView)
        if searching { empty.isHidden = true; navigationContent.isHidden = true; notice.isHidden = true; continueButton.isHidden = true }
    }
    private func sortedChildren(_ children: [NavigationItem]) -> [NavigationItem] {
        let modified = navigation.values.sort == "modified"
        return children.sorted { left, right in
            if left.directory != right.directory { return left.directory }
            if modified && left.modified != right.modified { return left.modified > right.modified }
            let name = left.title.localizedStandardCompare(right.title)
            return name == .orderedSame ? left.id < right.id : name == .orderedAscending
        }
    }
    private func load(_ item: NavigationItem) {
        guard item.directory, !item.loaded, !item.loading, let root = item.root else { return }
        item.loading = true
        let relative = item.relative
        tasks[item.id] = Task { [weak self, weak item] in
            guard let self, let item else { return }
            do {
                let service: WorkspaceService
                if let existing = navigation.services[root] ?? auxiliaryServices[root] { service = existing }
                else {
                    service = try await navigation.backend.perform { try $0.openWorkspace(path: root) }
                    guard !Task.isCancelled else { return }; auxiliaryServices[root] = service
                }
                let listing = try await Task.detached(priority: .userInitiated) { try service.list(path: relative, hidden: false) }.value
                guard !Task.isCancelled, !disposed else { return }
                let previous = item.children.map { ($0.id, $0.directory) }
                let children = listing.entries.map { entry in
                    let child = fileNode((root as NSString).appendingPathComponent(entry.path), prefix: item.id, directory: entry.directory)
                    child.root = root; child.relative = entry.path; child.modified = entry.modified; return child
                }
                item.children = sortedChildren(children)
                let structureChanged = previous.count != item.children.count || zip(previous, item.children).contains { old, child in
                    old.0 != child.id || old.1 != child.directory
                }
                item.loaded = true; item.loading = false; tasks.removeValue(forKey: item.id)
                if listing.truncated { notice.stringValue = localized("workspace.listTruncated"); notice.isHidden = false }
                // Metadata only affects presentation when it changes the
                // selected sort order; otherwise preserve native row state.
                if structureChanged && !showingOutline { rebuild() }
            } catch {
                guard !Task.isCancelled else { return }; item.loading = false; item.loaded = true
                notice.stringValue = userFacingError(error); notice.isHidden = false
            }
        }
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if showingOutline { return (item as? NavigationHeading)?.children.count ?? headings.count }
        guard let item = item as? NavigationItem else { return items.count }
        if item.directory && !item.loaded { load(item) }
        return item.children.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if showingOutline { return (item as? NavigationHeading)?.children[index] ?? headings[index] }
        return (item as? NavigationItem)?.children[index] ?? items[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let heading = item as? NavigationHeading { return !heading.children.isEmpty }
        guard let item = item as? NavigationItem else { return false }
        return item.section != nil || item.directory
    }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? NavigationItem)?.section != nil }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? NavigationItem)?.section == nil }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let item = item as? NavigationItem, item.section != nil {
            let label = NSTextField(labelWithString: item.title.uppercased())
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .labelColor.withAlphaComponent(0.65)
            return label
        }
        let cell = outlineView.makeView(withIdentifier: WorkspaceRowView.reuseIdentifier, owner: self) as? WorkspaceRowView ?? WorkspaceRowView(frame: .zero)
        if let heading = item as? NavigationHeading {
            let headingCell = outlineView.makeView(withIdentifier: OutlineHeadingCell.reuseIdentifier, owner: self) as? OutlineHeadingCell ?? OutlineHeadingCell(frame: .zero)
            headingCell.configure(title: heading.title.isEmpty ? localized("analysis.untitled") : heading.title, level: heading.level)
            return headingCell
        }
        else if let item = item as? NavigationItem {
            let name = navigation.values.show_extensions || item.directory ? item.title : (item.title as NSString).deletingPathExtension
            cell.configure(name: name, directory: item.directory); cell.toolTip = item.path
        }
        return cell
    }
    private func restoreHeadingExpansion() {
        func expand(_ nodes: [NavigationHeading]) {
            for heading in nodes where !collapsedHeadings.contains(heading.id) { outline.expandItem(heading); expand(heading.children) }
        }
        expand(headings)
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        if !applyingExpansion, let heading = notification.userInfo?["NSObject"] as? NavigationHeading { collapsedHeadings.remove(heading.id); return }
        guard !applyingExpansion, let item = notification.userInfo?["NSObject"] as? NavigationItem else { return }
        if item.section != nil { collapsedSections.remove(item.id) } else { expanded.insert(item.id); load(item) }; saveWindowState()
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        if !applyingExpansion, let heading = notification.userInfo?["NSObject"] as? NavigationHeading { collapsedHeadings.insert(heading.id); return }
        guard !applyingExpansion, let item = notification.userInfo?["NSObject"] as? NavigationItem else { return }
        if item.section != nil { collapsedSections.insert(item.id) } else { expanded.remove(item.id) }; saveWindowState()
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        if let item = outline.item(atRow: outline.selectedRow) as? NavigationItem { selectedID = item.id }
    }
    @objc private func clicked() { openSelection() }
    private func openSelection(row explicitRow: Int? = nil) {
        // During an NSOutlineView double action, clickedRow can be valid while
        // selectedRow still refers to the previous row. Prefer the event row so
        // a double-click always opens the file under the pointer.
        let row = explicitRow ?? (outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow)
        guard row >= 0, let item = outline.item(atRow: row) else { return }
        if outline.selectedRow != row {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        if let heading = item as? NavigationHeading { browsingOutline = false; onHeading?(heading.from, headingToken) }
        else if let item = item as? NavigationItem, !item.directory, let path = item.path { onOpen?(path, nil) }
    }
    func quickOpen() { onQuickOpen?() }
    func searchWorkspace() { onContentSearch?() }
    func showContentSearch() {
        navigation.contentSearch.show(root: currentRoot)
        presentContentSearch(); contentSearch.show(root: currentRoot, window: window)
    }
    private func presentContentSearch() {
        if !searching { browseOrigin = scroll.contentView.bounds.origin }
        searching = true; pages.isHidden = true; empty.isHidden = true; navigationContent.isHidden = true; notice.isHidden = true; continueButton.isHidden = true
        contentSearch.view.isHidden = false
    }
    private func hideContentSearch() {
        searching = false; contentSearch.view.isHidden = true; pages.isHidden = false; rebuild()
        scroll.contentView.scroll(to: browseOrigin); scroll.reflectScrolledClipView(scroll.contentView)
    }
    func detach() {
        guard !disposed else { return }; disposed = true
        navigation.sidebar.save()
        if let presentationObserver { navigation.sidebar.removeObserver(presentationObserver); self.presentationObserver = nil }
        if let searchObserver { navigation.contentSearch.removeObserver(searchObserver); self.searchObserver = nil }
        contentSearch.detach()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver); self.scrollObserver = nil }
        for task in tasks.values { task.cancel() }; tasks.removeAll()
        if let observer { navigation.removeObserver(observer) }; observer = nil
        // AppKit can retain a closed tab's view for a later layout pass. Clear
        // its floating row while this data source is still alive, then commit
        // an empty table before weak delegate/data-source references disappear.
        outline.floatsGroupRows = false
        outline.delegate = nil; outline.dataSource = nil; outline.reloadData()
        outline.target = nil; outline.onOpen = nil; outline.menu?.delegate = nil
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        contextItem = outline.item(atRow: outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow) as? NavigationItem
        func action(_ key: String, _ selector: Selector) { let entry = menu.addItem(withTitle: localized(key), action: selector, keyEquivalent: ""); entry.target = self }
        guard !showingOutline, let item = contextItem, let path = item.path else {
            action("navigation.addFolder", #selector(chooseFolder)); action("navigation.customize", #selector(showCustomization)); return
        }
        if item.relative.isEmpty && navigation.values.locations.contains(path) { action("navigation.removeLocation", #selector(removeLocation)); menu.addItem(.separator()) }
        action(navigation.values.favorites.contains(path) ? "navigation.unfavorite" : "navigation.favorite", #selector(toggleFavorite))
        action("workspace.reveal", #selector(revealFile)); action("navigation.copyPath", #selector(copyPath))
        if item.root != nil && !item.relative.isEmpty {
            menu.addItem(.separator())
            action("navigation.rename", #selector(renameFile))
            action("workspace.move", #selector(moveFile))
            action("navigation.duplicate", #selector(duplicateFile))
            action("workspace.trash", #selector(trashFile))
        }
        if item.root != nil {
            menu.addItem(.separator()); action("workspace.newFile", #selector(newFile)); action("workspace.newFolder", #selector(newFolder))
        }
    }
    @objc private func removeLocation() {
        guard let path = contextItem?.path else { return }
        Task { await navigation.change { $0.locations.removeAll { $0 == path } } }
    }
    @objc private func toggleFavorite() {
        guard let path = contextItem?.path else { return }
        Task { await navigation.change { if $0.favorites.contains(path) { $0.favorites.removeAll { $0 == path } } else { $0.favorites.append(path) } } }
    }
    @objc private func copyPath() {
        guard let path = contextItem?.path else { return }; NSPasteboard.general.clearContents()
        if !NSPasteboard.general.setString(path, forType: .string) { onError?(localized("error.clipboard")) }
    }
    @objc private func revealFile() { if let path = contextItem?.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
    private func askName(_ key: String, initial: String) async -> String? {
        guard let window else { return nil }
        let alert = NSAlert(); alert.messageText = localized(key); alert.informativeText = localized("navigation.nameDetail")
        let input = NSTextField(string: initial); input.frame.size = NSSize(width: 300, height: 24); alert.accessoryView = input; alert.window.initialFirstResponder = input
        alert.addButton(withTitle: localized("button.ok")); alert.addButton(withTitle: localized("button.cancel")); window.makeFirstResponder(input)
        guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return nil }
        return input.stringValue
    }
    private func mutate(_ operation: WorkspaceMutation, key: String, initial: String? = nil) {
        guard let item = contextItem, let root = item.root else { return }
        let source = item.relative, directory = item.directory ? item.relative : (item.relative as NSString).deletingLastPathComponent
        Task {
            guard let name = await askName(key, initial: initial ?? item.title), !name.isEmpty else { return }
            let destination = (directory as NSString).appendingPathComponent(name)
            let target = operation == .move || operation == .copy ? ((source as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name) : destination
            do {
                let service = try await navigation.backend.perform { try $0.openWorkspace(path: root) }
                try await Task.detached { try service.mutate(operation: operation, source: source, target: target) }.value
                if operation == .move, let old = item.path {
                    let new = (root as NSString).appendingPathComponent(target)
                    await navigation.change { config in config.favorites = config.favorites.map { $0 == old ? new : $0 } }
                }
                await navigation.refresh()
            } catch { reportFileFailure(error, moving: operation == .move) }
        }
    }
    @objc private func renameFile() { mutate(.move, key: "navigation.rename") }
    @objc private func moveFile() {
        guard let item = contextItem, let path = item.path, let root = item.root, let window else { return }
        Task {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.directoryURL = URL(fileURLWithPath: root); panel.prompt = localized("navigation.moveHere")
            guard await panel.beginSheetModal(for: window) == .OK, let destination = panel.url else { return }
            guard destination.path == root || destination.path.hasPrefix(root + "/") else { onError?(localized("navigation.moveInside")); return }
            let relative = destination.path == root ? item.title : String(destination.path.dropFirst(root.count + 1)) + "/" + item.title
            transfer(path, root: root, destination: relative, copy: false)
        }
    }
    @objc private func duplicateFile() {
        guard let name = contextItem?.title else { return }
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        mutate(.copy, key: "navigation.duplicate", initial: stem + " " + localized("navigation.copySuffix") + (ext.isEmpty ? "" : "." + ext))
    }
    @objc private func newFile() { mutate(.newFile, key: "workspace.newFile", initial: localized("document.defaultFilename")) }
    @objc private func newFolder() { mutate(.newDirectory, key: "workspace.newFolder", initial: localized("navigation.newFolderName")) }
    @objc private func trashFile() {
        guard let item = contextItem, let root = item.root, let window else { return }
        Task {
            let alert = NSAlert(); alert.messageText = localized("workspace.trashTitle", item.title); alert.informativeText = localized("workspace.trashDetail")
            alert.addButton(withTitle: localized("button.cancel")); alert.addButton(withTitle: localized("workspace.trash"))
            guard await alert.beginSheetModal(for: window) == .alertSecondButtonReturn else { return }
            do {
                let service = try await navigation.backend.perform { try $0.openWorkspace(path: root) }
                let relative = item.relative
                try await Task.detached { try service.trash(path: relative) }.value
                await navigation.refresh()
            } catch { reportFileFailure(error, moving: true) }
        }
    }
    private func reportFileFailure(_ error: Error, moving: Bool) {
        let detail = userFacingError(error)
        onError?(moving && (error as? BackendFailure)?.code == "busy" ? localized("navigation.closeBeforeMove") : detail)
    }
    private func transfer(_ source: String, root: String, destination: String, copy: Bool) {
        Task {
            do {
                let service = try await navigation.backend.perform { try $0.openWorkspace(path: root) }
                try await Task.detached { try service.transfer(source: source, target: destination, copy: copy) }.value
                if !copy {
                    let target = (root as NSString).appendingPathComponent(destination)
                    await navigation.change { config in
                        config.favorites = config.favorites.map { $0 == source ? target : $0.hasPrefix(source + "/") ? target + $0.dropFirst(source.count) : $0 }
                    }
                }
                await navigation.refresh()
                notice.stringValue = localized(copy ? "navigation.copied" : "navigation.moved"); notice.isHidden = false
            } catch { reportFileFailure(error, moving: !copy) }
        }
    }
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard !showingOutline, let item = item as? NavigationItem, let path = item.path else { return nil }
        let board = NSPasteboardItem(); board.setString(item.id, forType: dragType); board.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL); return board
    }
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard !showingOutline else { return [] }
        if let id = info.draggingPasteboard.string(forType: dragType), let source = nodes[id], let target = item as? NavigationItem {
            if target.section == "favorites" && id.hasPrefix("favorite:") || target.section == "locations" && id.hasPrefix("location:") { return .move }
            if target.directory, source.path != target.path { return NSApp.currentEvent?.modifierFlags.contains(.option) == true ? .copy : .move }
        }
        if info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return .copy }
        return []
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if let id = info.draggingPasteboard.string(forType: dragType), let source = nodes[id], let target = item as? NavigationItem {
            if let section = target.section, ["favorites", "locations"].contains(section), let path = source.path {
                Task { await navigation.change { values in
                    var list = section == "favorites" ? values.favorites : values.locations
                    guard let old = list.firstIndex(of: path) else { return }; list.remove(at: old)
                    list.insert(path, at: min(list.count, max(0, index - (old < index ? 1 : 0))))
                    if section == "favorites" { values.favorites = list } else { values.locations = list }
                } }; return true
            }
            if target.directory, let root = target.root, let path = source.path {
                let destination = (target.relative as NSString).appendingPathComponent(source.title)
                transfer(path, root: root, destination: destination, copy: NSApp.currentEvent?.modifierFlags.contains(.option) == true)
                return true
            }
            return false
        }
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        Task {
            for url in urls {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if let target = item as? NavigationItem, target.directory, let root = target.root {
                    transfer(url.path, root: root, destination: (target.relative as NSString).appendingPathComponent(url.lastPathComponent), copy: true)
                } else if isDirectory { await navigation.addLocation(url.path) } else { onOpen?(url.path, nil) }
            }
        }; return true
    }
}

// swiftlint:enable type_body_length
