import AppKit

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
        let title = SettingsForm.label("navigation.customizeTitle", size: 15, weight: .semibold)
        let done = NSButton(title: localized("button.done"), target: self, action: #selector(close)); done.bezelStyle = .inline; done.identifier = .init("sidebar-customization-done")
        let header = NSStackView(views: [title, NSView(), done]); header.alignment = .centerY
        header.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 12, right: 18)
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = body
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 16
        body.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 18, right: 18); body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), body.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), body.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        for child in [header, scroll] { child.translatesAutoresizingMaskIntoConstraints = false; root.addArrangedSubview(child); child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        header.setContentHuggingPriority(.required, for: .vertical)
        root.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: view.leadingAnchor), root.trailingAnchor.constraint(equalTo: view.trailingAnchor), root.topAnchor.constraint(equalTo: view.topAnchor), root.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        add(SettingsForm.label("navigation.customizeScope", size: 12))
        groups.orientation = .vertical; groups.alignment = .leading; groups.spacing = 6
        let paths: [(String, WritableKeyPath<NavigationPreferences, Bool>)] = [("favorites", \.show_favorites), ("locations", \.show_locations), ("open_files", \.show_open_files), ("recents", \.show_recents)]
        for (key, path) in paths {
            let toggle = checkbox("navigation." + key, path, id: "sidebar-group-" + key)
            let up = button("navigation.sectionUp", symbol: "chevron.up", id: "group-up-" + key) { [weak self] in self?.moveSection(key, -1) }
            let down = button("navigation.sectionDown", symbol: "chevron.down", id: "group-down-" + key) { [weak self] in self?.moveSection(key, 1) }
            up.setAccessibilityLabel(localized("navigation.sectionUp") + " · " + toggle.title); down.setAccessibilityLabel(localized("navigation.sectionDown") + " · " + toggle.title)
            let row = NSStackView(views: [toggle, NSView(), up, down]); row.spacing = 6; row.alignment = .centerY
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
            sectionRows[key] = row; sectionButtons[key] = (up, down)
        }
        add(section("navigation.visibleGroups", [groups], detail: "navigation.sectionOrderDetail"))
        locations.identifier = .init("sidebar-locations"); locations.headerView = nil; locations.style = .plain; locations.rowHeight = 44
        locations.backgroundColor = .controlBackgroundColor; locations.usesAlternatingRowBackgroundColors = true
        locations.addTableColumn(NSTableColumn(identifier: .init("location"))); locations.delegate = self; locations.dataSource = self
        locations.setAccessibilityLabel(localized("navigation.locations"))
        let locationScroll = NSScrollView(); locationScroll.documentView = locations; locationScroll.hasVerticalScroller = true; locationScroll.autohidesScrollers = true
        locationScroll.borderType = .bezelBorder; locationScroll.heightAnchor.constraint(equalToConstant: 132).isActive = true
        let addFolder = button("navigation.addFolder", id: "add-location") { [weak self] in self?.addFolder() }
        let remove = button("navigation.removeLocation", symbol: "minus", id: "remove-location") { [weak self] in self?.removeLocation() }
        let up = button("navigation.locationUp", symbol: "chevron.up", id: "location-up") { [weak self] in self?.moveLocation(-1) }
        let down = button("navigation.locationDown", symbol: "chevron.down", id: "location-down") { [weak self] in self?.moveLocation(1) }
        locationButtons = [up, down, remove]
        let controls = NSStackView(views: [addFolder, remove, NSView(), up, down]); controls.spacing = 6; controls.alignment = .centerY
        locationDetail.font = .systemFont(ofSize: 11); locationDetail.textColor = .secondaryLabelColor
        add(section("navigation.locations", [locationScroll, controls, locationDetail]))
        let options = [("navigation.follow", \NavigationPreferences.follow_active), ("navigation.showRoot", \.show_root), ("navigation.extensions", \.show_extensions), ("navigation.compact", \.compact)].map { checkbox($0.0, $0.1, id: $0.0) }
        add(section("navigation.displayOptions", options))
    }
    private func section(_ key: String, _ controls: [NSView], detail: String? = nil) -> NSStackView {
        var children: [NSView] = [SettingsForm.label(key, size: 12, weight: .semibold)] + controls
        if let detail { children.append(SettingsForm.label(detail, size: 11)) }
        return SettingsForm.stack(children, spacing: 8)
    }
    private func add(_ child: NSView) {
        body.addArrangedSubview(child); child.translatesAutoresizingMaskIntoConstraints = false
        child.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -36).isActive = true
    }
    private func button(_ key: String, symbol: String? = nil, id: String, action: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: localized(key), target: self, action: #selector(activateControl(_:)))
        button.bezelStyle = .rounded; button.controlSize = .small; button.identifier = .init(id)
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); button.toolTip = button.title; button.setAccessibilityLabel(button.title)
            button.title = ""; button.imagePosition = .imageOnly
        }
        actions[ObjectIdentifier(button)] = action; return button
    }
    private func render() {
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
