import AppKit

@MainActor
final class SettingsWindowController: NSWindowController {
    let languageControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let groupLabel = NSTextField(labelWithString: "")
    private let languageLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let selectLanguage: (InterfaceLanguage) async throws -> Void
    private let values: () -> EditorPreferences?
    private let apply: (EditorPreferences) async throws -> Void
    private let appearanceControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fontControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let heightControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let widthControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private var labels: [(NSTextField, String)] = []
    private var checks: [(NSButton, String, WritableKeyPath<EditorPreferences, Bool>)] = []
    private(set) var applyingLanguage = false
    private(set) var lastError: String?

    init(selectLanguage: @escaping (InterfaceLanguage) async throws -> Void,
         values: @escaping () -> EditorPreferences?, apply: @escaping (EditorPreferences) async throws -> Void) {
        self.selectLanguage = selectLanguage
        self.values = values; self.apply = apply
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 570),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        groupLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        languageLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        languageControl.target = self; languageControl.action = #selector(languageChanged(_:))
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.textColor = .systemOrange
        errorLabel.isHidden = true
        let row = NSStackView(views: [languageLabel, NSView(), languageControl])
        row.alignment = .centerY; row.spacing = 16
        func preferenceRow(_ key: String, _ control: NSPopUpButton) -> NSStackView {
            let label = NSTextField(labelWithString: ""); labels.append((label, key))
            control.target = self; control.action = #selector(preferenceChanged(_:))
            let row = NSStackView(views: [label, NSView(), control]); row.alignment = .centerY
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
            return row
        }
        let extraRows = [preferenceRow("settings.appearance", appearanceControl), preferenceRow("settings.fontSize", fontControl),
                         preferenceRow("settings.lineHeight", heightControl), preferenceRow("settings.pageWidth", widthControl)]
        for (key, path) in [("settings.autosave", \EditorPreferences.auto_save), ("settings.spellcheck", \EditorPreferences.spell_check),
                            ("settings.continueLists", \EditorPreferences.continue_lists), ("settings.codeWrap", \EditorPreferences.code_wrap),
                            ("settings.codeNumbers", \EditorPreferences.code_numbers)] {
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(preferenceChanged(_:)))
            checks.append((button, key, path))
        }
        let layout = NSStackView(views: [groupLabel, row, detailLabel] + extraRows + checks.map { $0.0 } + [errorLabel])
        layout.orientation = .vertical; layout.alignment = .leading; layout.spacing = 14
        layout.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            layout.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            layout.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            layout.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -20),
            row.widthAnchor.constraint(equalTo: layout.widthAnchor),
            languageControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            detailLabel.widthAnchor.constraint(equalTo: layout.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: layout.widthAnchor),
        ])
        for row in extraRows { row.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true }
        relocalize()
    }

    required init?(coder: NSCoder) { fatalError("Use init(selectLanguage:)") }

    func relocalize() {
        window?.title = localized("settings.title")
        groupLabel.stringValue = localized("settings.general")
        languageLabel.stringValue = localized("settings.language")
        detailLabel.stringValue = localized("settings.languageDetail")
        languageControl.setAccessibilityLabel(localized("settings.languageAccessibility"))
        languageControl.removeAllItems()
        for (title, preference) in [(localized("language.system"), InterfaceLanguage.system), ("English", .english), ("简体中文", .simplifiedChinese)] {
            languageControl.addItem(withTitle: title)
            languageControl.lastItem?.representedObject = preference.rawValue
        }
        if let index = languageControl.itemArray.firstIndex(where: { $0.representedObject as? String == LanguagePreferences.shared.preference.rawValue }) {
            languageControl.selectItem(at: index)
        }
        languageControl.isEnabled = !applyingLanguage
        errorLabel.stringValue = lastError ?? ""
        errorLabel.isHidden = lastError == nil
        for (label, key) in labels { label.stringValue = localized(key) }
        if let values = values() {
            func populate(_ control: NSPopUpButton, _ entries: [(String, String)], _ selected: String) {
                control.removeAllItems()
                var entries = entries
                if !entries.contains(where: { $0.1 == selected }) { entries.append((selected, selected)) }
                for (label, raw) in entries { control.addItem(withTitle: label); control.lastItem?.representedObject = raw }
                control.selectItem(at: entries.firstIndex(where: { $0.1 == selected }) ?? 0); control.isEnabled = !applyingLanguage
            }
            populate(appearanceControl, [(localized("language.system"), "system"), (localized("settings.light"), "light"), (localized("settings.dark"), "dark")], values.theme)
            populate(fontControl, [14, 15, 16, 17, 18, 20, 22, 24, 28, 32].map { (String($0), String($0)) }, String(values.font_size))
            populate(heightControl, [120, 140, 150, 160, 170, 180, 200, 220].map { ("\($0)%", String($0)) }, String(values.line_height))
            populate(widthControl, [(localized("settings.adaptiveWidth"), "adaptive")] + [600, 720, 820, 960, 1080, 1200, 1400].map { ("\($0) px", String($0)) }, values.content_width == "adaptive" ? "adaptive" : String(values.page_width))
            for (button, key, path) in checks { button.title = localized(key); button.state = values[keyPath: path] ? .on : .off; button.isEnabled = !applyingLanguage }
        }
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard !applyingLanguage, let raw = sender.selectedItem?.representedObject as? String,
              let preference = InterfaceLanguage(rawValue: raw) else { return }
        applyingLanguage = true; lastError = nil; languageControl.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            do { try await selectLanguage(preference) }
            catch { lastError = error.localizedDescription }
            applyingLanguage = false
            relocalize()
        }
    }
    @objc private func preferenceChanged(_ sender: NSControl) {
        guard !applyingLanguage, var next = values() else { return }
        if sender === appearanceControl { next.theme = appearanceControl.selectedItem?.representedObject as? String ?? next.theme }
        if sender === widthControl, let raw = widthControl.selectedItem?.representedObject as? String {
            next.content_width = raw == "adaptive" ? "adaptive" : "fixed"
            if let number = UInt32(raw) { next.page_width = number }
        }
        for (control, path) in [(fontControl, \EditorPreferences.font_size), (heightControl, \EditorPreferences.line_height)] where sender === control {
            if let raw = control.selectedItem?.representedObject as? String, let number = UInt32(raw) { next[keyPath: path] = number }
        }
        for (button, _, path) in checks where sender === button { next[keyPath: path] = button.state == .on }
        applyingLanguage = true; lastError = nil; relocalize()
        Task { [weak self] in
            guard let self else { return }
            do { try await apply(next) } catch { lastError = error.localizedDescription }
            applyingLanguage = false; relocalize()
        }
    }
}
