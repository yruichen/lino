import AppKit

@MainActor
final class SidebarCustomizationController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSPopoverDelegate {
    private let navigation: NavigationCoordinator
    private let popover = NSPopover()
    private let body = SettingsPageStack()
    private let locations = NSTableView()
    private var actions: [ObjectIdentifier: () -> Void] = [:]
    private var locationButtons: [NSButton] = []
    private var selectedLocation: String?
    private var applying = false
    private var observer: UUID?
    private weak var parentWindow: NSWindow?
    init(navigation: NavigationCoordinator) { self.navigation = navigation; super.init() }
    func show(relativeTo anchor: NSView) {
        parentWindow = anchor.window; popover.delegate = self
        if observer == nil { observer = navigation.observe { [weak self] _ in guard let self, popover.isShown, !applying else { return }; render() } }
        let content = NSViewController(), root = NSStackView()
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 0
        let title = SettingsForm.label("navigation.customizeTitle", size: 15, weight: .semibold)
        let done = NSButton(title: localized("button.done"), target: self, action: #selector(close)); done.bezelStyle = .inline; done.identifier = .init("sidebar-customization-done")
        let header = NSStackView(views: [title, NSView(), done]); header.alignment = .centerY
        header.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 12, right: 18)
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = body
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 18
        body.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 18, right: 18); body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), body.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), body.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        for child in [header, scroll] { child.translatesAutoresizingMaskIntoConstraints = false; root.addArrangedSubview(child); child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        header.setContentHuggingPriority(.required, for: .vertical)
        let size = NSSize(width: 400, height: min(690, max(440, (anchor.window?.frame.height ?? 800) - 110)))
        // A scroll view has no intrinsic height. Give the popover a normal
        // content view so its fitting pass cannot collapse to the header.
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        root.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: container.leadingAnchor), root.trailingAnchor.constraint(equalTo: container.trailingAnchor), root.topAnchor.constraint(equalTo: container.topAnchor), root.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
        content.view = container; content.preferredContentSize = size
        popover.contentViewController = content; popover.behavior = .transient; popover.contentSize = size
        locations.headerView = nil; locations.style = .plain; locations.rowHeight = 44
        if locations.tableColumns.isEmpty { locations.addTableColumn(NSTableColumn(identifier: .init("location"))) }
        locations.delegate = self; locations.dataSource = self
        render(); popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
    private func add(_ view: NSView) {
        body.addArrangedSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -36).isActive = true
    }
    private func button(_ key: String, symbol: String? = nil, id: String, enabled: Bool = true, action: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: localized(key), target: self, action: #selector(activateControl(_:)))
        button.bezelStyle = .rounded; button.identifier = .init(id); button.isEnabled = enabled && !applying
        if let symbol { button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); button.toolTip = button.title; button.setAccessibilityLabel(button.title); button.title = ""; button.imagePosition = .imageOnly }
        actions[ObjectIdentifier(button)] = action; return button
    }
    private func render() {
        let focused = (popover.contentViewController?.view.window?.firstResponder as? NSView)?.identifier
        for child in body.arrangedSubviews { body.removeArrangedSubview(child); child.removeFromSuperview() }
        actions.removeAll(); locationButtons.removeAll()
        add(SettingsForm.label("navigation.customizeDetail", size: 12))
        let values = navigation.values
        let paths: [String: WritableKeyPath<NavigationPreferences, Bool>] = ["favorites": \.show_favorites, "locations": \.show_locations, "open_files": \.show_open_files, "recents": \.show_recents]
        var groups: [NSView] = []
        for (index, key) in values.sections.enumerated() {
            guard let path = paths[key] else { continue }
            let toggle = checkbox("navigation." + key, path, id: "sidebar-group-" + key)
            let up = button("navigation.sectionUp", symbol: "chevron.up", id: "group-up-" + key, enabled: index > 0) { [weak self] in self?.moveSection(key, -1) }
            let down = button("navigation.sectionDown", symbol: "chevron.down", id: "group-down-" + key, enabled: index + 1 < values.sections.count) { [weak self] in self?.moveSection(key, 1) }
            up.setAccessibilityLabel(localized("navigation.sectionUp") + " · " + toggle.title); down.setAccessibilityLabel(localized("navigation.sectionDown") + " · " + toggle.title)
            let row = NSStackView(views: [toggle, NSView(), up, down]); row.spacing = 6; row.alignment = .centerY; groups.append(row)
        }
        add(SettingsForm.group("navigation.visibleGroups", groups, detail: "navigation.sectionOrderDetail"))
        let locationScroll = NSScrollView(); locationScroll.documentView = locations; locationScroll.hasVerticalScroller = true; locationScroll.autohidesScrollers = true
        locationScroll.borderType = .lineBorder; locationScroll.heightAnchor.constraint(equalToConstant: 116).isActive = true
        let selected = selectedLocation
        locations.reloadData()
        if let selected, let index = values.locations.firstIndex(of: selected) { locations.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); selectedLocation = selected }
        else { locations.deselectAll(nil) }
        let addFolder = button("navigation.addFolder", id: "add-location") { [weak self] in self?.addFolder() }
        let up = button("navigation.locationUp", symbol: "chevron.up", id: "location-up") { [weak self] in self?.moveLocation(-1) }
        let down = button("navigation.locationDown", symbol: "chevron.down", id: "location-down") { [weak self] in self?.moveLocation(1) }
        let remove = button("navigation.removeLocation", id: "remove-location") { [weak self] in self?.removeLocation() }
        locationButtons = [up, down, remove]; updateLocationButtons()
        let controls = NSStackView(views: [addFolder, NSView(), up, down]); controls.spacing = 6
        add(SettingsForm.group("navigation.locations", [locationScroll, controls, remove], detail: values.locations.isEmpty ? "navigation.customizeNoLocations" : "navigation.removeLocationDetail"))
        let options = [("navigation.follow", \NavigationPreferences.follow_active), ("navigation.showRoot", \.show_root), ("navigation.extensions", \.show_extensions), ("navigation.compact", \.compact)].map { checkbox($0.0, $0.1, id: $0.0) }
        add(SettingsForm.group("navigation.displayOptions", options))
        if let focused {
            func find(_ view: NSView) -> NSView? { if view.identifier == focused { return view }; return view.subviews.lazy.compactMap(find).first }
            if let target = find(body) { target.window?.makeFirstResponder(target) }
        }
    }
    private func checkbox(_ key: String, _ path: WritableKeyPath<NavigationPreferences, Bool>, id: String) -> NSButton {
        let toggle = NSButton(checkboxWithTitle: localized(key), target: self, action: #selector(activateControl(_:)))
        toggle.identifier = .init(id); toggle.state = navigation.values[keyPath: path] ? .on : .off; toggle.isEnabled = !applying
        actions[ObjectIdentifier(toggle)] = { [weak self, weak toggle] in guard let self, let toggle else { return }; let on = toggle.state == .on; commit { $0[keyPath: path] = on } }; return toggle
    }
    @objc private func activateControl(_ sender: NSControl) { actions[ObjectIdentifier(sender)]?() }
    func popoverDidClose(_ notification: Notification) { if let observer { navigation.removeObserver(observer); self.observer = nil } }
    @objc private func close() { popover.performClose(nil) }
    private func commit(_ change: @escaping @MainActor (inout NavigationPreferences) -> Void) {
        guard !applying else { return }; applying = true
        func disable(_ view: NSView) { (view as? NSControl)?.isEnabled = false; view.subviews.forEach(disable) }; disable(body)
        Task { [weak self] in guard let self else { return }; await navigation.change(change); applying = false; render() }
    }
    private func moveSection(_ key: String, _ delta: Int) {
        commit { values in guard let index = values.sections.firstIndex(of: key), values.sections.indices.contains(index + delta) else { return }; values.sections.swapAt(index, index + delta) }
    }
    private func moveLocation(_ delta: Int) {
        guard let path = selectedLocation else { return }
        commit { values in guard let index = values.locations.firstIndex(of: path), values.locations.indices.contains(index + delta) else { return }; values.locations.swapAt(index, index + delta) }
    }
    private func removeLocation() { guard let path = selectedLocation else { return }; selectedLocation = nil; commit { $0.locations.removeAll { $0 == path } } }
    private func updateLocationButtons() {
        let index = selectedLocation.flatMap { navigation.values.locations.firstIndex(of: $0) }
        guard locationButtons.count == 3 else { return }
        locationButtons[0].isEnabled = !applying && (index ?? 0) > 0
        locationButtons[1].isEnabled = !applying && index.map { $0 + 1 < navigation.values.locations.count } == true
        locationButtons[2].isEnabled = !applying && index != nil
    }
    func numberOfRows(in tableView: NSTableView) -> Int { navigation.values.locations.count }
    func tableViewSelectionDidChange(_ notification: Notification) { selectedLocation = navigation.values.locations.indices.contains(locations.selectedRow) ? navigation.values.locations[locations.selectedRow] : nil; updateLocationButtons() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard navigation.values.locations.indices.contains(row) else { return nil }
        let path = navigation.values.locations[row], cell = WorkspaceRowView(frame: .zero)
        cell.configure(name: URL(fileURLWithPath: path).lastPathComponent, directory: true, excerpt: path); cell.toolTip = path; return cell
    }
    private func addFolder() {
        guard let parentWindow else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: parentWindow) { [weak self] response in
            guard let self, response == .OK, let path = panel.url?.path else { return }
            Task { selectedLocation = await navigation.addLocation(path); render() }
        }
    }
}
