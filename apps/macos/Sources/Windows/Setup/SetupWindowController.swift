import AppKit

@MainActor
final class SetupWindowController: NSWindowController, NSWindowDelegate {
    private let installation: InstallationServices
    private let openFile: () -> Void
    private let openFolder: () -> Void
    private let finish: () -> Void
    private let status = NSTextField(wrappingLabelWithString: "")
    private let defaultButton = NSButton()
    private let locationStatus = NSTextField(wrappingLabelWithString: "")
    private var changingDefault = false
    init(installation: InstallationServices = InstallationServices(), openFile: @escaping () -> Void, openFolder: @escaping () -> Void, finish: @escaping () -> Void = {}) {
        self.installation = installation; self.openFile = openFile; self.openFolder = openFolder; self.finish = finish
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 670), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 560, height: 540); window.center()
        super.init(window: window); window.delegate = self; relocalize()
    }
    required init?(coder: NSCoder) { fatalError("Use init(installation:openFile:openFolder:finish:)") }
    func relocalize() {
        guard let window else { return }
        window.title = localized("setup.title")
        window.backgroundColor = ThemePalette.color("bg")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = true; scroll.backgroundColor = ThemePalette.color("bg")
        let body = SettingsPageStack(); body.orientation = .vertical; body.alignment = .leading; body.spacing = 20
        body.edgeInsets = NSEdgeInsets(top: 26, left: 28, bottom: 26, right: 28)
        body.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = body; window.contentView = scroll
        body.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        body.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor).isActive = true
        body.topAnchor.constraint(equalTo: scroll.contentView.topAnchor).isActive = true
        func add(_ view: NSView) { body.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -56).isActive = true }
        func button(_ key: String, _ action: Selector) -> NSButton {
            let result = NSButton(title: localized(key), target: self, action: action); result.bezelStyle = .rounded; result.identifier = .init(key); return result
        }
        add(SettingsForm.label("setup.title", size: 26, weight: .semibold)); add(SettingsForm.label("setup.intro"))
        locationStatus.font = .systemFont(ofSize: 12); locationStatus.identifier = .init("setup-location")
        add(SettingsForm.group("setup.install", [locationStatus, button("setup.applications", #selector(applications))], detail: "setup.installDetail"))
        status.font = .systemFont(ofSize: 12); status.identifier = .init("setup-default-status")
        defaultButton.title = localized("setup.makeDefault"); defaultButton.target = self; defaultButton.action = #selector(makeDefault); defaultButton.bezelStyle = .rounded; defaultButton.identifier = .init("setup.makeDefault")
        add(SettingsForm.group("setup.association", [status, defaultButton], detail: "setup.associationDetail"))
        add(SettingsForm.group("setup.access", [button("setup.openFile", #selector(chooseFile)), button("setup.openFolder", #selector(chooseFolder)), button("setup.permissions", #selector(permissions))], detail: "setup.accessDetail"))
        let done = button("setup.start", #selector(done)); done.keyEquivalent = "\r"; add(done)
        refresh()
    }
    func refresh() {
        locationStatus.stringValue = localized(installation.installed ? "setup.installed" : "setup.moveFirst")
        status.stringValue = localized(installation.isDefault ? "setup.defaultAlready" : "setup.defaultOptional")
        status.textColor = .secondaryLabelColor
        defaultButton.isEnabled = installation.installed && !installation.isDefault && !changingDefault
    }
    func windowDidBecomeKey(_ notification: Notification) { if !changingDefault { refresh() } }
    @objc private func applications() { installation.showApplications() }
    @objc private func permissions() { installation.showPermissions() }
    @objc private func chooseFile() { close(); finish(); openFile() }
    @objc private func chooseFolder() { close(); finish(); openFolder() }
    @objc private func done() { close(); finish() }
    @objc private func makeDefault() {
        guard !changingDefault, installation.installed else { return }
        changingDefault = true; defaultButton.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            do {
                try await installation.makeDefault(); changingDefault = false; refresh()
                if !installation.isDefault { status.stringValue = localized("setup.defaultUnchanged") }
            } catch {
                changingDefault = false; refresh(); status.stringValue = localized("setup.defaultFailed"); status.textColor = ThemePalette.color("error")
            }
        }
    }
}
