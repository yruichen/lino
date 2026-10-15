import AppKit
import UniformTypeIdentifiers

@MainActor
enum DocumentDialogs {
    static func open(in window: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = localized("dialog.openTitle"); panel.prompt = localized("dialog.openPrompt")
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .text, .image, .pdf]
        panel.allowsOtherFileTypes = true
        let response: NSApplication.ModalResponse
        if let window { response = await panel.beginSheetModal(for: window) }
        else { response = await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0) } } }
        return response == .OK ? panel.url : nil
    }
    static func save(in window: NSWindow, label: String?, resourceNote: Bool = false) async -> URL? {
        let panel = NSSavePanel()
        panel.title = localized("dialog.saveTitle"); panel.prompt = localized("button.save")
        panel.nameFieldLabel = localized("dialog.saveName")
        panel.nameFieldStringValue = label ?? localized("document.defaultFilename")
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsOtherFileTypes = true
        if resourceNote {
            let note = NSTextField(wrappingLabelWithString: localized("media.saveLocationNote"))
            note.frame = NSRect(x: 0, y: 0, width: 380, height: 44)
            note.textColor = .secondaryLabelColor; panel.accessoryView = note
        }
        let response = await panel.beginSheetModal(for: window)
        return response == .OK ? panel.url : nil
    }
    enum Decision { case save, discard, cancel }
    static func unsaved(in window: NSWindow, label: String, closing: Bool = false) async -> Decision {
        let alert = NSAlert()
        alert.messageText = localized(closing ? "dialog.closeUnsavedTitle" : "dialog.unsavedTitle", label)
        alert.informativeText = localized("dialog.unsavedDetail")
        alert.addButton(withTitle: localized(closing ? "dialog.saveClose" : "menu.save"))
        alert.addButton(withTitle: localized("dialog.keepEditing"))
        alert.addButton(withTitle: localized(closing ? "dialog.discardClose" : "dialog.discardChanges"))
        switch await alert.beginSheetModal(for: window) {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }
}

extension DocumentDialogs {
    static func closeUnavailable(in window: NSWindow) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = localized("dialog.unavailableTitle")
        alert.informativeText = localized("dialog.unavailableDetail")
        alert.addButton(withTitle: localized("dialog.keepEditing"))
        alert.addButton(withTitle: localized("dialog.closeKeepRecovery"))
        return await alert.beginSheetModal(for: window) == .alertSecondButtonReturn
    }

    enum RecoveryDecision { case restore(String), discard(String), later }

    static func recovery(in window: NSWindow, entries: [RecoveryEntry]) async -> RecoveryDecision {
        let alert = NSAlert()
        alert.messageText = localized("recovery.title")
        alert.informativeText = localized("recovery.detail")
        let restore = alert.addButton(withTitle: localized("recovery.restore"))
        alert.addButton(withTitle: localized("recovery.later"))
        alert.addButton(withTitle: localized("recovery.discardSelected"))
        let selection = RecoverySelection(entries: entries, restoreButton: restore)
        alert.accessoryView = selection.view
        let result = await alert.beginSheetModal(for: window)
        let entry = entries[selection.selectedIndex]
        switch result {
        case .alertFirstButtonReturn:
            return entry.problem == nil ? .restore(entry.key) : .later
        case .alertThirdButtonReturn:
            let confirmation = NSAlert()
            confirmation.alertStyle = .warning
            confirmation.messageText = localized("recovery.discardTitle", entry.label ?? localized("document.untitled"))
            confirmation.informativeText = localized("recovery.discardDetail")
            confirmation.addButton(withTitle: localized("button.keep"))
            confirmation.addButton(withTitle: localized("recovery.discardCopy"))
            return await confirmation.beginSheetModal(for: window) == .alertSecondButtonReturn ? .discard(entry.key) : .later
        default: return .later
        }
    }
}

@MainActor
private final class RecoverySelection: NSObject {
    let view = NSStackView()
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let entries: [RecoveryEntry]
    private let restoreButton: NSButton
    var selectedIndex: Int { max(0, popup.indexOfSelectedItem) }

    init(entries: [RecoveryEntry], restoreButton: NSButton) {
        self.entries = entries; self.restoreButton = restoreButton
        super.init()
        for entry in entries {
            popup.addItem(withTitle: "\(entry.label ?? localized("document.untitled"))\(entry.problem == nil ? "" : localized("recovery.unreadableSuffix"))")
        }
        popup.target = self; popup.action = #selector(changed)
        popup.setAccessibilityLabel(localized("recovery.selectionLabel"))
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        view.orientation = .vertical; view.alignment = .leading; view.spacing = 10
        view.addArrangedSubview(popup); view.addArrangedSubview(detail)
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 72)
        popup.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        detail.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        changed()
    }
    @objc private func changed() {
        let entry = entries[selectedIndex]
        restoreButton.isEnabled = entry.problem == nil
        detail.stringValue = entry.problem == nil ? localized("recovery.durabilityDetail") : localized("recovery.readError")
        detail.toolTip = entry.problem
    }
}
