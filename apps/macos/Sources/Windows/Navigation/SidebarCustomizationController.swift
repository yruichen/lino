import AppKit

@MainActor
private final class SidebarSettingRow: NSView {
    private let content: NSStackView

    init(views: [NSView]) {
        content = NSStackView(views: views)
        super.init(frame: .zero)
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init(views:)") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        ThemePalette.color("border").setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: 10, y: 0.5))
        divider.line(to: NSPoint(x: bounds.width - 10, y: 0.5))
        divider.lineWidth = 1
        divider.stroke()
    }
}

@MainActor
final class SidebarCustomizationController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSPopoverDelegate {
    let view = NSView()
    private let navigation: NavigationCoordinator
    private let popover = NSPopover()
    private let body = SettingsPageStack()
    private let groups = NSStackView()
    private let locations = NSTableView()
    private let locationDetail = NSTextField(wrappingLabelWithString: "")
    private var actions: [ObjectIdentifier: () -> Void] = [:]
    private var toggles: [(NSButton, WritableKeyPath<NavigationPreferences, Bool>)] = []
    private var sectionRows: [String: NSView] = [:]
    private var sectionButtons: [String: (NSButton, NSButton)] = [:]
    private var locationButtons: [NSButton] = []
    private var renderedLocations: [String] = []
    private var selectedLocation: String?
    private var applying = false
    private var updatingSelection = false
    private var observer: UUID?
    private weak var parentWindow: NSWindow?

    init(navigation: NavigationCoordinator) {
        self.navigation = navigation; super.init(); buildContent(); render()
    }
    func show(relativeTo anchor: NSView) {
        parentWindow = anchor.window; popover.delegate = self
        if observer == nil { observer = navigation.observe { [weak self] _ in guard let self, popover.isShown, !applying else { return }; render() } }
        let size = NSSize(width: 400, height: min(660, max(440, (anchor.window?.frame.height ?? 800) - 100)))
        let content = NSViewController(); content.view = view; content.preferredContentSize = size
        view.setFrameSize(size)
        popover.contentViewController = content; popover.behavior = .transient; popover.contentSize = size
        render(); popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
    private func buildContent() {
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 0
        let background = ThemeSurface(role: "sidebar")
        background.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            background.topAnchor.constraint(equalTo: view.topAnchor),
            background.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let title = SettingsForm.label("navigation.customizeTitle", size: 15, weight: .semibold)
        let done = NSButton(title: localized("button.done"), target: self, action: #selector(close))
        done.bezelStyle = .inline; done.isBordered = false; done.contentTintColor = ThemePalette.color("accent"); done.identifier = .init("sidebar-customization-done")
        let header = NSStackView(views: [title, NSView(), done]); header.alignment = .centerY
        header.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 12, right: 18)
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = body
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 14
        body.edgeInsets = NSEdgeInsets(top: 2, left: 18, bottom: 18, right: 18); body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), body.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), body.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        for child in [header, scroll] { child.translatesAutoresizingMaskIntoConstraints = false; root.addArrangedSubview(child); child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        header.setContentHuggingPriority(.required, for: .vertical)
        root.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: view.leadingAnchor), root.trailingAnchor.constraint(equalTo: view.trailingAnchor), root.topAnchor.constraint(equalTo: view.topAnchor), root.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        add(SettingsForm.label("navigation.customizeScope", size: 12))
        groups.orientation = .vertical; groups.alignment = .leading; groups.spacing = 4
        let paths: [(String, WritableKeyPath<NavigationPreferences, Bool>)] = [("favorites", \.show_favorites), ("locations", \.show_locations), ("open_files", \.show_open_files), ("recents", \.show_recents)]
        for (key, path) in paths {
            let toggle = checkbox("navigation." + key, path, id: "sidebar-group-" + key)
            let up = button("navigation.sectionUp", symbol: "chevron.up", id: "group-up-" + key) { [weak self] in self?.moveSection(key, -1) }
            let down = button("navigation.sectionDown", symbol: "chevron.down", id: "group-down-" + key) { [weak self] in self?.moveSection(key, 1) }
            up.setAccessibilityLabel(localized("navigation.sectionUp") + " · " + toggle.title); down.setAccessibilityLabel(localized("navigation.sectionDown") + " · " + toggle.title)
            let row = settingRow([toggle, NSView(), up, down])
            sectionRows[key] = row; sectionButtons[key] = (up, down)
        }
        add(section("navigation.visibleGroups", [groups], detail: "navigation.sectionOrderDetail"))
        locations.identifier = .init("sidebar-locations"); locations.headerView = nil; locations.style = .sourceList; locations.rowHeight = 44
        locations.backgroundColor = ThemePalette.color("surface"); locations.usesAlternatingRowBackgroundColors = false
        locations.gridStyleMask = []; locations.intercellSpacing = NSSize(width: 0, height: 1)
        locations.addTableColumn(NSTableColumn(identifier: .init("location"))); locations.delegate = self; locations.dataSource = self
        locations.setAccessibilityLabel(localized("navigation.locations"))
        let locationScroll = NSScrollView(); locationScroll.documentView = locations; locationScroll.hasVerticalScroller = true; locationScroll.autohidesScrollers = true
        locationScroll.borderType = .noBorder; locationScroll.heightAnchor.constraint(equalToConstant: 88).isActive = true
        locationScroll.setContentHuggingPriority(.required, for: .vertical)
        locationScroll.setContentCompressionResistancePriority(.required, for: .vertical)
        let addFolder = button("navigation.addFolder", id: "add-location") { [weak self] in self?.addFolder() }
        let remove = button("navigation.removeLocation", symbol: "minus", id: "remove-location") { [weak self] in self?.removeLocation() }
        let up = button("navigation.locationUp", symbol: "chevron.up", id: "location-up") { [weak self] in self?.moveLocation(-1) }
        let down = button("navigation.locationDown", symbol: "chevron.down", id: "location-down") { [weak self] in self?.moveLocation(1) }
        locationButtons = [up, down, remove]
        let controls = settingRow([addFolder, remove, NSView(), up, down])
        locationDetail.font = .systemFont(ofSize: 11); locationDetail.textColor = .secondaryLabelColor
        add(section("navigation.locations", [locationScroll, controls, locationDetail]))
        let optionKeys: [(String, WritableKeyPath<NavigationPreferences, Bool>)] = [
            ("navigation.follow", \.follow_active),
            ("navigation.showRoot", \.show_root),
            ("navigation.extensions", \.show_extensions),
            ("navigation.compact", \.compact),
        ]
        let options = optionKeys.map { settingRow([checkbox($0.0, $0.1, id: $0.0)]) }
        add(section("navigation.displayOptions", options))
    }
    private func settingRow(_ views: [NSView]) -> NSView {
        SidebarSettingRow(views: views)
    }

    private func section(_ key: String, _ controls: [NSView], detail: String? = nil) -> NSStackView {
        SettingsForm.group(key, controls, detail: detail)
    }
    private func add(_ child: NSView) {
        body.addArrangedSubview(child); child.translatesAutoresizingMaskIntoConstraints = false
        child.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -36).isActive = true
    }
    private func button(_ key: String, symbol: String? = nil, id: String, action: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: localized(key), target: self, action: #selector(activateControl(_:)))
        button.bezelStyle = symbol == nil ? .rounded : .inline
        button.controlSize = .small; button.identifier = .init(id)
        button.contentTintColor = ThemePalette.color(symbol == nil ? "accent" : "muted")
        if let symbol {
            button.isBordered = false; button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.toolTip = button.title; button.setAccessibilityLabel(button.title); button.title = ""
            button.imagePosition = .imageOnly; button.imageScaling = .scaleProportionallyDown
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        actions[ObjectIdentifier(button)] = action; return button
    }
    private func render() {
        ThemePalette.refresh(view)
        let values = navigation.values
        let orderedRows = values.sections.compactMap { sectionRows[$0] }
        if groups.arrangedSubviews != orderedRows {
            for child in groups.arrangedSubviews { groups.removeArrangedSubview(child); child.removeFromSuperview() }
            for row in orderedRows { groups.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: groups.widthAnchor).isActive = true }
        }
        for (toggle, path) in toggles { toggle.state = values[keyPath: path] ? .on : .off }
        func enable(_ child: NSView) { (child as? NSControl)?.isEnabled = !applying; child.subviews.forEach(enable) }; enable(body)
        for (index, key) in values.sections.enumerated() {
            sectionButtons[key]?.0.isEnabled = !applying && index > 0
            sectionButtons[key]?.1.isEnabled = !applying && index + 1 < values.sections.count
        }
        if renderedLocations != values.locations {
            let selected = selectedLocation, origin = locations.enclosingScrollView?.contentView.bounds.origin ?? .zero
            updatingSelection = true
            locations.reloadData(); renderedLocations = values.locations
            if let selected, let index = values.locations.firstIndex(of: selected) { locations.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
            else { selectedLocation = nil; locations.deselectAll(nil) }
            locations.enclosingScrollView?.contentView.scroll(to: origin)
            updatingSelection = false
        }
        locationDetail.stringValue = localized(values.locations.isEmpty ? "navigation.customizeNoLocations" : "navigation.removeLocationDetail")
        updateLocationButtons()
    }
    private func checkbox(_ key: String, _ path: WritableKeyPath<NavigationPreferences, Bool>, id: String) -> NSButton {
        let toggle = NSButton(checkboxWithTitle: localized(key), target: self, action: #selector(activateControl(_:)))
        toggle.controlSize = .regular; toggle.contentTintColor = ThemePalette.color("text")
        toggle.identifier = .init(id); toggles.append((toggle, path))
        actions[ObjectIdentifier(toggle)] = { [weak self, weak toggle] in guard let self, let toggle else { return }; let on = toggle.state == .on; commit { $0[keyPath: path] = on } }; return toggle
    }
    @objc private func activateControl(_ sender: NSControl) { actions[ObjectIdentifier(sender)]?() }
    func popoverDidClose(_ notification: Notification) { if let observer { navigation.removeObserver(observer); self.observer = nil } }
    @objc private func close() { popover.performClose(nil) }
    private func commit(_ change: @escaping @MainActor (inout NavigationPreferences) -> Void) {
        guard !applying else { return }; applying = true; render()
        Task { [weak self] in guard let self else { return }; await navigation.change(change); applying = false; render() }
    }
    private func moveSection(_ key: String, _ delta: Int) {
        commit { values in guard let index = values.sections.firstIndex(of: key), values.sections.indices.contains(index + delta) else { return }; values.sections.swapAt(index, index + delta) }
    }
    private func moveLocation(_ delta: Int) {
        guard let path = selectedLocation else { return }
        commit { values in guard let index = values.locations.firstIndex(of: path), values.locations.indices.contains(index + delta) else { return }; values.locations.swapAt(index, index + delta) }
    }
    private func removeLocation() { guard let path = selectedLocation else { return }; commit { $0.locations.removeAll { $0 == path } } }
    private func updateLocationButtons() {
        let index = selectedLocation.flatMap { navigation.values.locations.firstIndex(of: $0) }
        guard locationButtons.count == 3 else { return }
        locationButtons[0].isEnabled = !applying && (index ?? 0) > 0
        locationButtons[1].isEnabled = !applying && index.map { $0 + 1 < navigation.values.locations.count } == true
        locationButtons[2].isEnabled = !applying && index != nil
    }
    func numberOfRows(in tableView: NSTableView) -> Int { navigation.values.locations.count }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection else { return }
        selectedLocation = navigation.values.locations.indices.contains(locations.selectedRow) ? navigation.values.locations[locations.selectedRow] : nil; updateLocationButtons()
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard navigation.values.locations.indices.contains(row) else { return nil }
        let path = navigation.values.locations[row]
        let cell = tableView.makeView(withIdentifier: WorkspaceRowView.reuseIdentifier, owner: self) as? WorkspaceRowView ?? WorkspaceRowView(frame: .zero)
        cell.configure(name: URL(fileURLWithPath: path).lastPathComponent, directory: true, excerpt: path); cell.toolTip = path; return cell
    }
    private func addFolder() {
        guard !applying, let parentWindow else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: parentWindow) { [weak self] response in
            guard let self, response == .OK, let path = panel.url?.path else { return }
            applying = true; render()
            Task { selectedLocation = await navigation.addLocation(path); applying = false; render() }
        }
    }
}
