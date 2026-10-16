import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    let languageControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let values: () -> EditorPreferences?
    private let apply: (EditorPreferences) async throws -> Void
    private let selectLanguage: (InterfaceLanguage) async throws -> Void
    private let navigation: NavigationCoordinator
    private let updates: UpdateCoordinator
    private var updateObserver: UUID?
    private let updateStatus = NSTextField(wrappingLabelWithString: "")
    private let updateDate = NSTextField(labelWithString: "")
    private let updateButton = NSButton()
    private let releaseButton = NSButton()
    private lazy var customization = SidebarCustomizationController(navigation: navigation)
    private let categories = ["general", "appearance", "writing", "editing", "files", "navigation", "updates"]
    private let symbols = ["gearshape", "circle.lefthalf.filled", "line.3.horizontal", "pencil", "doc", "sidebar.left", "arrow.triangle.2.circlepath"]
    private let table = NSTableView()
    private let page = NSScrollView()
    private let body = SettingsPageStack()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var bindings: [ObjectIdentifier: (NSControl, inout EditorPreferences) -> Void] = [:]
    private var navigationBindings: [ObjectIdentifier: WritableKeyPath<NavigationPreferences, Bool>] = [:]
    private(set) var applyingLanguage = false
    private(set) var lastError: String?
    private(set) var selectedCategory = "general"

    init(selectLanguage: @escaping (InterfaceLanguage) async throws -> Void,
         values: @escaping () -> EditorPreferences?, apply: @escaping (EditorPreferences) async throws -> Void,
         navigation: NavigationCoordinator, updates: UpdateCoordinator) {
        self.selectLanguage = selectLanguage; self.values = values; self.apply = apply; self.navigation = navigation; self.updates = updates
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 740, height: 560); window.center()
        window.titlebarAppearsTransparent = true; window.titlebarSeparatorStyle = .none
        window.backgroundColor = ThemePalette.color("bg")
        super.init(window: window)
        let root = ThemeSurface(role: "bg"), sidebar = ThemeSurface(role: "sidebar")
        window.contentView = root
        let contentGuide = installWindowChrome(in: window, content: root)
        table.addTableColumn(NSTableColumn(identifier: .init("category"))); table.headerView = nil
        table.rowHeight = 36; table.style = .sourceList; table.backgroundColor = .clear
        table.delegate = self; table.dataSource = self; table.selectionHighlightStyle = .regular
        let menu = NSScrollView(); menu.documentView = table; menu.drawsBackground = false
        sidebar.addSubview(menu); root.addSubview(sidebar); root.addSubview(page)
        menu.translatesAutoresizingMaskIntoConstraints = false; sidebar.translatesAutoresizingMaskIntoConstraints = false; page.translatesAutoresizingMaskIntoConstraints = false
        page.hasVerticalScroller = true; page.drawsBackground = false; page.documentView = body
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 22; body.translatesAutoresizingMaskIntoConstraints = false
        body.edgeInsets = NSEdgeInsets(top: 28, left: 28, bottom: 28, right: 28)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebar.topAnchor.constraint(equalTo: contentGuide.topAnchor), sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 180),
            menu.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8), menu.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8), menu.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 18), menu.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -8),
            page.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), page.trailingAnchor.constraint(equalTo: root.trailingAnchor), page.topAnchor.constraint(equalTo: contentGuide.topAnchor), page.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: page.contentView.leadingAnchor), body.topAnchor.constraint(equalTo: page.contentView.topAnchor), body.widthAnchor.constraint(equalTo: page.contentView.widthAnchor),
        ])
        errorLabel.font = .systemFont(ofSize: 12); errorLabel.textColor = ThemePalette.color("error"); errorLabel.identifier = .init("theme-error")
        languageControl.target = self; languageControl.action = #selector(languageChanged(_:))
        updateButton.target = self; updateButton.action = #selector(checkUpdates); updateButton.bezelStyle = .rounded; updateButton.identifier = .init("check-updates")
        releaseButton.target = self; releaseButton.action = #selector(openRelease); releaseButton.bezelStyle = .rounded
        updateStatus.font = .systemFont(ofSize: 13); updateStatus.identifier = .init("update-status"); updateDate.font = .systemFont(ofSize: 11); updateDate.textColor = .secondaryLabelColor
        updateObserver = updates.observe { [weak self] in self?.refreshUpdateStatus() }
        relocalize(); table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }
    required init?(coder: NSCoder) { fatalError("Use init(selectLanguage:values:apply:navigation:)") }
    func selectCategory(_ category: String) {
        guard let index = categories.firstIndex(of: category) else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { categories.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView(), label = NSTextField(labelWithString: localized("settings." + categories[row]))
        label.font = .systemFont(ofSize: 13); label.textColor = ThemePalette.color("text"); label.lineBreakMode = .byTruncatingTail
        let icon = NSImageView(image: NSImage(systemSymbolName: symbols[row], accessibilityDescription: nil)!)
        icon.contentTintColor = ThemePalette.color("muted")
        let stack = NSStackView(views: [icon, label]); stack.spacing = 10; stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(stack); cell.textField = label; cell.imageView = icon
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 16)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard categories.indices.contains(table.selectedRow) else { return }
        selectedCategory = categories[table.selectedRow]; render(); page.contentView.scroll(to: .zero)
    }
    func relocalize() {
        window?.title = localized("settings.title"); languageControl.removeAllItems()
        for (key, raw) in [("language.system", "system"), ("language.english", "en"), ("language.chinese", "zh-Hans")] {
            languageControl.addItem(withTitle: localized(key)); languageControl.lastItem?.representedObject = raw
        }
        languageControl.selectItem(at: languageControl.itemArray.firstIndex { $0.representedObject as? String == values()?.language } ?? 0)
        languageControl.setAccessibilityLabel(localized("settings.languageAccessibility")); languageControl.isEnabled = !applyingLanguage
        table.reloadData()
        if let index = categories.firstIndex(of: selectedCategory), table.selectedRow != index { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        render()
    }
    private func add(_ view: NSView) { body.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -56).isActive = true }
    private func render() {
        for view in body.arrangedSubviews { body.removeArrangedSubview(view); view.removeFromSuperview() }
        bindings.removeAll(); navigationBindings.removeAll()
        add(SettingsForm.label("settings." + selectedCategory, size: 23, weight: .semibold))
        add(SettingsForm.label("settings." + selectedCategory + "Detail", size: 12))
        guard let value = values() else { return }
        switch selectedCategory {
        case "general":
            add(SettingsForm.group("settings.interface", [SettingsForm.row("settings.language", languageControl)], detail: "settings.languageDetail"))
            let setup = NSButton(title: localized("setup.openGuide"), target: NSApp.delegate, action: #selector(EditorApplication.showSetup)); setup.bezelStyle = .rounded
            add(SettingsForm.group("setup.association", [setup], detail: "setup.settingsDetail"))
        case "appearance":
            let mode = popup([("language.system", "system"), ("settings.light", "light"), ("settings.dark", "dark")], selected: value.theme) { control, next in next.theme = (control as! NSPopUpButton).selectedItem?.representedObject as? String ?? next.theme }
            add(SettingsForm.group("settings.appearance", [SettingsForm.row("settings.appearanceMode", mode)]))
            let themes = ThemePalette.builtins + value.custom_themes
            let lightLabel = SettingsForm.label("settings.light", size: 11), darkLabel = SettingsForm.label("settings.dark", size: 11)
            var choices: [[NSView]] = [[NSView(), lightLabel, darkLabel]]
            for theme in themes {
                let choice = ThemeChoiceButton(theme, target: self, action: #selector(themeSelected(_:)))
                choice.chosen = theme.id == value.theme_family; choice.isEnabled = !applyingLanguage
                choices.append([choice, ThemeChoiceButton.preview(theme.light, theme: theme), ThemeChoiceButton.preview(theme.dark, theme: theme)])
            }
            let grid = NSGridView(views: choices)
            grid.columnSpacing = 12; grid.rowSpacing = 8; grid.yPlacement = .center
            grid.column(at: 0).xPlacement = .leading
            grid.column(at: 1).width = 92; grid.column(at: 2).width = 92
            grid.column(at: 1).xPlacement = .center; grid.column(at: 2).xPlacement = .center
            add(SettingsForm.group("settings.themeFamily", [grid]))
            add(AppearancePreviewView(frame: .zero))
            let glass = popup([("settings.glassSolid", "solid"), ("settings.glassRegular", "regular"), ("settings.glassClear", "clear")], selected: value.glass_style) { control, next in next.glass_style = (control as! NSPopUpButton).selectedItem?.representedObject as? String ?? "solid" }
            add(SettingsForm.group("settings.glass", [SettingsForm.row("settings.glassStyle", glass), SettingsForm.row("settings.surfaceOpacity", percentage(value.surface_opacity, \EditorPreferences.surface_opacity))], detail: "settings.glassDetail"))
            let choose = NSButton(title: localized("settings.chooseBackground"), target: self, action: #selector(chooseBackground)); choose.bezelStyle = .rounded
            let remove = NSButton(title: localized("settings.removeBackground"), target: self, action: #selector(removeBackground)); remove.bezelStyle = .rounded; remove.isEnabled = !value.background_image.isEmpty && !applyingLanguage
            choose.isEnabled = !applyingLanguage
            let backgroundControls = NSStackView(views: [choose, remove]); backgroundControls.spacing = 8
            let backgroundName = NSTextField(labelWithString: AppearanceImage.failure ?? (AppearanceImage.name.isEmpty ? localized("settings.noBackground") : AppearanceImage.name)); backgroundName.font = .systemFont(ofSize: 12); backgroundName.lineBreakMode = .byTruncatingMiddle
            add(SettingsForm.group("settings.background", [backgroundName, backgroundControls, SettingsForm.row("settings.backgroundOpacity", percentage(value.background_opacity, \EditorPreferences.background_opacity))], detail: "settings.backgroundDetail"))
            let export = NSButton(title: localized("settings.exportTheme"), target: self, action: #selector(exportTheme))
            let load = NSButton(title: localized("settings.importTheme"), target: self, action: #selector(importTheme))
            let controls = NSStackView(views: [export, load]); controls.spacing = 8
            for button in [export, load] { button.bezelStyle = .rounded; button.isEnabled = !applyingLanguage }
            if value.theme_family.hasPrefix("custom-") {
                let remove = NSButton(title: localized("settings.removeTheme"), target: self, action: #selector(removeTheme)); remove.bezelStyle = .rounded; remove.isEnabled = !applyingLanguage; controls.addArrangedSubview(remove)
            }
            add(SettingsForm.group("settings.customThemes", [controls], detail: "settings.customThemesDetail"))
        case "writing":
            let theme = ThemePalette.selected(value), font = NSComboBox()
            font.addItems(withObjectValues: [localized("settings.themeFont")] + NSFontManager.shared.availableFontFamilies.sorted())
            font.stringValue = value.body_font.isEmpty ? localized("settings.themeFont") : value.body_font
            bind(font) { control, next in let raw = (control as! NSComboBox).stringValue.trimmingCharacters(in: .whitespaces); next.body_font = raw == localized("settings.themeFont") ? "" : raw }
            let size = numeric(value.use_theme_font_size ? theme.font_size : value.font_size, range: 10...40) { next, number in next.font_size = number; next.use_theme_font_size = false }
            let height = numeric(value.use_theme_line_height ? theme.line_height : value.line_height, range: 100...240) { next, number in next.line_height = number; next.use_theme_line_height = false }
            add(SettingsForm.group("settings.bodyType", [SettingsForm.row("settings.bodyFont", font), SettingsForm.row("settings.fontSize", size), check("settings.themeSize", value.use_theme_font_size, \EditorPreferences.use_theme_font_size), SettingsForm.row("settings.lineHeight", height), check("settings.themeHeight", value.use_theme_line_height, \EditorPreferences.use_theme_line_height)]))
            let width = popup([("settings.adaptiveWidth", "adaptive"), ("settings.fixedWidth", "fixed")], selected: value.content_width) { control, next in next.content_width = (control as! NSPopUpButton).selectedItem?.representedObject as? String ?? next.content_width }
            let widthValue = numeric(value.page_width, range: 400...2000) { next, number in next.page_width = number; next.content_width = "fixed" }
            add(SettingsForm.group("settings.layout", [SettingsForm.row("settings.pageWidth", width), SettingsForm.row("settings.fixedWidthValue", widthValue)], detail: "settings.widthDetail"))
        case "editing":
            add(SettingsForm.group("settings.input", [check("settings.spellcheck", value.spell_check, \EditorPreferences.spell_check), check("settings.continueLists", value.continue_lists, \EditorPreferences.continue_lists)]))
            add(SettingsForm.group("settings.code", [check("settings.codeWrap", value.code_wrap, \EditorPreferences.code_wrap), check("settings.codeNumbers", value.code_numbers, \EditorPreferences.code_numbers)], detail: "settings.codeDetail"))
        case "files":
            add(SettingsForm.group("settings.saving", [check("settings.autosave", value.auto_save, \EditorPreferences.auto_save)], detail: "settings.autosaveDetail"))
            let images = popup([("settings.imageReference", "reference"), ("settings.imageCopy", "copy")], selected: value.image_insertion) { control, next in next.image_insertion = (control as! NSPopUpButton).selectedItem?.representedObject as? String ?? "reference" }
            add(SettingsForm.group("settings.images", [SettingsForm.row("settings.imageInsertion", images)], detail: "settings.imageInsertionDetail"))
        case "navigation":
            var checks: [NSView] = []
            for (key, path) in [("navigation.showFavorites", \NavigationPreferences.show_favorites), ("navigation.showLocations", \NavigationPreferences.show_locations), ("navigation.showOpenFiles", \NavigationPreferences.show_open_files), ("navigation.showRecents", \NavigationPreferences.show_recents), ("navigation.follow", \NavigationPreferences.follow_active), ("navigation.showRoot", \NavigationPreferences.show_root), ("navigation.extensions", \NavigationPreferences.show_extensions), ("navigation.compact", \NavigationPreferences.compact)] {
                let button = NSButton(checkboxWithTitle: localized(key), target: self, action: #selector(navigationChanged(_:)))
                button.state = navigation.values[keyPath: path] ? .on : .off; navigationBindings[ObjectIdentifier(button)] = path; checks.append(button)
            }
            add(SettingsForm.group("settings.sidebar", checks))
            let sources = NSButton(title: localized("settings.organizeNavigation"), target: self, action: #selector(customizeNavigation(_:))); sources.bezelStyle = .rounded
            let addFolder = NSButton(title: localized("navigation.addFolder"), target: self, action: #selector(addNavigationFolder)); addFolder.bezelStyle = .rounded
            let sourceControls = NSStackView(views: [addFolder, sources]); sourceControls.spacing = 8
            add(SettingsForm.group("settings.locations", [sourceControls], detail: "settings.locationsDetail"))
        case "updates":
            let version = NSTextField(labelWithString: localized("updates.currentVersion", updates.currentVersion)); version.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            let controls = NSStackView(views: [updateButton, releaseButton]); controls.spacing = 8
            add(SettingsForm.group("updates.version", [version, updateStatus, updateDate, controls], detail: "updates.source"))
            add(SettingsForm.group("updates.preferences", [check("updates.automatic", value.automatic_update_checks, \EditorPreferences.automatic_update_checks), check("updates.includeBeta", value.include_prerelease_updates, \EditorPreferences.include_prerelease_updates)], detail: "updates.preferencesDetail"))
            refreshUpdateStatus()
        default: break
        }
        errorLabel.stringValue = lastError ?? ""; errorLabel.isHidden = lastError == nil; add(errorLabel)
        window?.backgroundColor = ThemePalette.color("bg")
    }
    @objc private func checkUpdates() { updates.check() }
    @objc private func openRelease() { updates.openRelease() }
    private func refreshUpdateStatus() {
        updateButton.title = localized("updates.checkNow"); updateButton.isEnabled = true
        releaseButton.title = localized("updates.browseReleases"); releaseButton.isHidden = false
        updateStatus.textColor = .labelColor
        switch updates.state {
        case .idle: updateStatus.stringValue = localized("updates.ready")
        case .checking: updateStatus.stringValue = localized("updates.checking"); updateButton.isEnabled = false
        case .checked(let result):
            if let release = result.release {
                updateStatus.stringValue = result.newer ? localized("updates.available", release.version) : localized("updates.current")
                releaseButton.title = localized("updates.viewRelease")
            } else { updateStatus.stringValue = localized("updates.noReleases") }
        case .failed(let message):
            updateStatus.stringValue = message
            if let previous = updates.lastResult?.release { updateStatus.stringValue += "\n" + localized("updates.previousResult", previous.version) }
            updateStatus.textColor = ThemePalette.color("error")
        }
        if let date = updates.lastChecked { updateDate.stringValue = localized("updates.lastChecked", DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)) }
        else { updateDate.stringValue = "" }
        updateDate.isHidden = updateDate.stringValue.isEmpty
    }
    private func bind(_ control: NSControl, _ change: @escaping (NSControl, inout EditorPreferences) -> Void) {
        control.target = self; control.action = #selector(preferenceChanged(_:)); control.isEnabled = !applyingLanguage
        bindings[ObjectIdentifier(control)] = change
    }
    private func popup(_ entries: [(String, String)], selected: String, change: @escaping (NSControl, inout EditorPreferences) -> Void) -> NSPopUpButton {
        let popup = NSPopUpButton()
        for (key, raw) in entries { popup.addItem(withTitle: localized(key)); popup.lastItem?.representedObject = raw }
        popup.selectItem(at: entries.firstIndex { $0.1 == selected } ?? 0); bind(popup, change); return popup
    }
    private func numeric(_ value: UInt32, range: ClosedRange<UInt32>, change: @escaping (inout EditorPreferences, UInt32) -> Void) -> NSTextField {
        let field = NSTextField(string: String(value)); field.alignment = .right
        field.cell?.sendsActionOnEndEditing = true
        let formatter = NumberFormatter(); formatter.allowsFloats = false; formatter.minimum = NSNumber(value: range.lowerBound); formatter.maximum = NSNumber(value: range.upperBound)
        field.formatter = formatter
        bind(field) { control, next in let raw = (control as! NSTextField).integerValue; if raw >= Int(range.lowerBound), raw <= Int(range.upperBound) { change(&next, UInt32(raw)) } }
        return field
    }
    private func check(_ key: String, _ value: Bool, _ path: WritableKeyPath<EditorPreferences, Bool>) -> NSButton {
        let button = NSButton(checkboxWithTitle: localized(key), target: nil, action: nil); button.state = value ? .on : .off
        button.identifier = .init(key)
        bind(button) { control, next in next[keyPath: path] = (control as! NSButton).state == .on }; return button
    }
    private func percentage(_ value: UInt32, _ path: WritableKeyPath<EditorPreferences, UInt32>) -> NSView {
        let slider = NSSlider(value: Double(value), minValue: 0, maxValue: 100, target: nil, action: nil)
        slider.isContinuous = false
        bind(slider) { control, next in next[keyPath: path] = UInt32((control as! NSSlider).integerValue) }
        let label = NSTextField(labelWithString: "\(value)%"); label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let row = NSStackView(views: [slider, label]); row.spacing = 8; slider.widthAnchor.constraint(equalToConstant: 136).isActive = true
        return row
    }
    @objc private func chooseBackground() {
        guard !applyingLanguage, let window else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            applyBackgroundSelection(url)
        }
    }
    func applyBackgroundSelection(_ url: URL) {
        guard !applyingLanguage, var next = values() else { return }
        do { next.background_image = try AppearanceImage.select(url); submit(next) }
        catch { lastError = localized("settings.backgroundInvalid"); render() }
    }
    @objc private func removeBackground() { guard var next = values() else { return }; next.background_image = ""; submit(next) }
    @objc private func preferenceChanged(_ sender: NSControl) {
        guard !applyingLanguage, var next = values(), let change = bindings[ObjectIdentifier(sender)] else { return }
        change(sender, &next); submit(next)
    }
    private func submit(_ next: EditorPreferences, imported: Bool = false) {
        guard !applyingLanguage else { return }; applyingLanguage = true; lastError = nil; render()
        Task { [weak self] in
            guard let self else { return }
            do { try await apply(next) }
            catch { lastError = imported && (error as? BackendFailure)?.code == "invalid_message" ? localized("settings.themeInvalidData") : userFacingError(error) }
            applyingLanguage = false; relocalize()
        }
    }
    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard !applyingLanguage, let raw = sender.selectedItem?.representedObject as? String, let language = InterfaceLanguage(rawValue: raw) else { return }
        applyingLanguage = true; lastError = nil; languageControl.isEnabled = false
        Task { [weak self] in guard let self else { return }; do { try await selectLanguage(language) } catch { lastError = userFacingError(error) }; applyingLanguage = false; relocalize() }
    }
    @objc private func themeSelected(_ sender: ThemeChoiceButton) { guard sender.isEnabled, var next = values() else { return }; next.theme_family = sender.definition.id; submit(next) }
    @objc private func navigationChanged(_ sender: NSButton) {
        guard let path = navigationBindings[ObjectIdentifier(sender)] else { return }; let value = sender.state == .on
        Task { await navigation.change { $0[keyPath: path] = value }; render() }
    }
    @objc private func customizeNavigation(_ sender: NSButton) { customization.show(relativeTo: sender) }
    @objc private func addNavigationFolder() {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let path = panel.url?.path else { return }
            Task { await navigation.addLocation(path); render() }
        }
    }
    @objc private func removeTheme() { guard var next = values() else { return }; next.custom_themes.removeAll { $0.id == next.theme_family }; next.theme_family = "paper"; submit(next) }
    @objc private func exportTheme() {
        guard let value = values(), let window else { return }
        var definition = ThemePalette.selected(value)
        if !definition.id.hasPrefix("custom-") { definition.id = "custom-" + definition.id; definition.name = definition.light.displayName + " / " + definition.dark.displayName }
        let panel = NSSavePanel(); panel.nameFieldStringValue = definition.id + ".json"; panel.allowedContentTypes = [.json]
        let template = definition
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(template).write(to: url, options: .atomic) }
            catch { self?.lastError = localized("settings.themeExportFailed"); self?.render() }
        }
    }
    @objc private func importTheme() {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                importDefinition(try Data(contentsOf: url))
            } catch { lastError = localized("settings.themeImportFailed"); render() }
        }
    }
    func importDefinition(_ data: Data) {
        guard !applyingLanguage, var next = values() else { return }
        do {
            let definition = try JSONDecoder().decode(ThemeDefinition.self, from: data)
            next.custom_themes.removeAll { $0.id == definition.id }; next.custom_themes.append(definition); next.theme_family = definition.id
            submit(next, imported: true)
        } catch { lastError = localized("settings.themeImportFailed"); render() }
    }
}
