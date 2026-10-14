import AppKit

@MainActor
final class SidebarCustomizationController: NSObject {
    private let navigation: NavigationCoordinator
    private let popover = NSPopover()
    private var checks: [(NSButton, WritableKeyPath<NavigationPreferences, Bool>)] = []
    private let location = NSPopUpButton()
    private let section = NSPopUpButton()
    init(navigation: NavigationCoordinator) { self.navigation = navigation; super.init() }
    func show(relativeTo anchor: NSView) {
        let content = NSViewController(), stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 11
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        let title = NSTextField(labelWithString: localized("navigation.customize")); title.font = .systemFont(ofSize: 14, weight: .semibold); stack.addArrangedSubview(title)
        checks = []
        for (key, path) in [
            ("navigation.showFavorites", \NavigationPreferences.show_favorites), ("navigation.showLocations", \NavigationPreferences.show_locations),
            ("navigation.showOpenFiles", \NavigationPreferences.show_open_files), ("navigation.showRecents", \NavigationPreferences.show_recents),
            ("navigation.follow", \NavigationPreferences.follow_active), ("navigation.showRoot", \NavigationPreferences.show_root),
            ("navigation.extensions", \NavigationPreferences.show_extensions), ("navigation.compact", \NavigationPreferences.compact),
        ] {
            let button = NSButton(checkboxWithTitle: localized(key), target: self, action: #selector(toggle(_:)))
            button.state = navigation.values[keyPath: path] ? .on : .off; checks.append((button, path)); stack.addArrangedSubview(button)
        }
        location.removeAllItems()
        for path in navigation.values.locations { location.addItem(withTitle: URL(fileURLWithPath: path).lastPathComponent); location.lastItem?.representedObject = path }
        location.setAccessibilityLabel(localized("navigation.locations"))
        let locationUp = NSButton(title: "↑", target: self, action: #selector(locationUp))
        let locationDown = NSButton(title: "↓", target: self, action: #selector(locationDown))
        let remove = NSButton(title: "−", target: self, action: #selector(removeLocation))
        for button in [locationUp, locationDown, remove] { button.bezelStyle = .rounded; button.isEnabled = !navigation.values.locations.isEmpty }
        remove.toolTip = localized("navigation.removeLocation")
        stack.addArrangedSubview(NSTextField(labelWithString: localized("navigation.locations")))
        let sources = NSStackView(views: [location, locationUp, locationDown, remove]); sources.spacing = 6; stack.addArrangedSubview(sources)
        let separator = NSBox(); separator.boxType = .separator; stack.addArrangedSubview(separator)
        section.removeAllItems()
        for key in navigation.values.sections { section.addItem(withTitle: localized("navigation." + key)); section.lastItem?.representedObject = key }
        let up = NSButton(image: NSImage(systemSymbolName: "arrow.up", accessibilityDescription: localized("navigation.sectionUp"))!, target: self, action: #selector(moveUp))
        let down = NSButton(image: NSImage(systemSymbolName: "arrow.down", accessibilityDescription: localized("navigation.sectionDown"))!, target: self, action: #selector(moveDown))
        up.bezelStyle = .rounded; down.bezelStyle = .rounded
        stack.addArrangedSubview(NSTextField(labelWithString: localized("navigation.sectionOrder")))
        let row = NSStackView(views: [section, up, down]); row.spacing = 8; stack.addArrangedSubview(row)
        content.view = stack; popover.contentViewController = content; popover.behavior = .transient
        popover.contentSize = NSSize(width: max(300, stack.fittingSize.width), height: stack.fittingSize.height)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
    @objc private func toggle(_ sender: NSButton) {
        guard let path = checks.first(where: { $0.0 === sender })?.1 else { return }
        let value = sender.state == .on
        Task { await navigation.change { $0[keyPath: path] = value }; sender.state = navigation.values[keyPath: path] ? .on : .off }
    }
    private func move(_ delta: Int) {
        guard let key = section.selectedItem?.representedObject as? String else { return }
        Task {
            await navigation.change { values in
                guard let index = values.sections.firstIndex(of: key), values.sections.indices.contains(index + delta) else { return }
                values.sections.swapAt(index, index + delta)
            }
            section.removeAllItems()
            for value in navigation.values.sections { section.addItem(withTitle: localized("navigation." + value)); section.lastItem?.representedObject = value }
            section.selectItem(at: navigation.values.sections.firstIndex(of: key) ?? 0)
        }
    }
    @objc private func moveUp() { move(-1) }
    @objc private func moveDown() { move(1) }
}

extension SidebarCustomizationController {
    private func reorderLocation(_ delta: Int) {
        guard let path = location.selectedItem?.representedObject as? String else { return }
        Task {
            await navigation.change { values in
                guard let index = values.locations.firstIndex(of: path), values.locations.indices.contains(index + delta) else { return }
                values.locations.swapAt(index, index + delta)
            }
            reloadLocations(selected: path)
        }
    }
    private func reloadLocations(selected: String?) {
        location.removeAllItems()
        for path in navigation.values.locations { location.addItem(withTitle: URL(fileURLWithPath: path).lastPathComponent); location.lastItem?.representedObject = path }
        if let selected, let index = navigation.values.locations.firstIndex(of: selected) { location.selectItem(at: index) }
    }
    @objc private func locationUp() { reorderLocation(-1) }
    @objc private func locationDown() { reorderLocation(1) }
    @objc private func removeLocation() {
        guard let path = location.selectedItem?.representedObject as? String else { return }
        Task { await navigation.change { $0.locations.removeAll { $0 == path } }; reloadLocations(selected: nil) }
    }
}
