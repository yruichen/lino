import AppKit

@MainActor
final class SettingsWindowController: NSWindowController {
    let languageControl = NSPopUpButton(frame: .zero, pullsDown: false)
    private let groupLabel = NSTextField(labelWithString: "")
    private let languageLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let selectLanguage: (InterfaceLanguage) async throws -> Void
    private(set) var applyingLanguage = false
    private(set) var lastError: String?

    init(selectLanguage: @escaping (InterfaceLanguage) async throws -> Void) {
        self.selectLanguage = selectLanguage
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
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
        let layout = NSStackView(views: [groupLabel, row, detailLabel, errorLabel])
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
}
