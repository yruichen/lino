import AppKit

/// A single decision per screen: install the downloaded app, or begin writing.
@MainActor
final class SetupWindowController: NSWindowController, NSWindowDelegate {
    enum Mode: Equatable { case install, welcome }
    private let installation: InstallationServices
    private let mode: Mode
    private let newDocument: () -> Void
    private let openFile: () -> Void
    private let finish: () -> Void
    private let install: () async throws -> Void
    private let tryWithoutInstalling: () -> Void
    private let status = NSTextField(wrappingLabelWithString: "")
    private let primary = NSButton()
    private let secondary = NSButton()
    private let extra = NSButton()
    private let spinner = NSProgressIndicator()
    private var acted = false
    private var recoveryURL: URL?
    private(set) var installing = false

    init(installation: InstallationServices = InstallationServices(), mode: Mode = .welcome,
         newDocument: @escaping () -> Void = {}, openFile: @escaping () -> Void,
         finish: @escaping () -> Void = {},
         install: @escaping () async throws -> Void = {}, tryWithoutInstalling: @escaping () -> Void = {}) {
        self.installation = installation; self.mode = mode; self.newDocument = newDocument
        self.openFile = openFile; self.finish = finish
        self.install = install; self.tryWithoutInstalling = tryWithoutInstalling
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true; window.center()
        super.init(window: window); window.delegate = self; relocalize()
    }
    required init?(coder: NSCoder) { fatalError("Use init(installation:mode:newDocument:openFile:finish:install:tryWithoutInstalling:)") }
    func relocalize() {
        guard let window else { return }
        window.title = localized(mode == .install ? "setup.installTitle" : "setup.title")
        window.backgroundColor = .windowBackgroundColor
        let root = NSView(); window.contentView = root
        let icon = NSImageView(image: NSImage(named: NSImage.applicationIconName) ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = NSTextField(labelWithString: window.title); title.font = .systemFont(ofSize: 29, weight: .semibold); title.textColor = .labelColor; title.alignment = .center
        let subtitle = NSTextField(wrappingLabelWithString: localized(mode == .install ? "setup.installSubtitle" : "setup.writeSubtitle"))
        subtitle.font = .systemFont(ofSize: 14); subtitle.textColor = .secondaryLabelColor; subtitle.alignment = .center
        primary.title = localized(mode == .install ? "setup.installAndOpen" : "setup.newDocument")
        primary.identifier = .init(mode == .install ? "setup.installAndOpen" : "setup.newDocument")
        primary.target = self; primary.action = mode == .install ? #selector(installApp) : #selector(createDocument)
        primary.keyEquivalent = "\r"; primary.bezelStyle = .rounded; primary.controlSize = .large
        secondary.title = localized(mode == .install ? "setup.tryFirst" : "setup.openFile")
        secondary.identifier = .init(mode == .install ? "setup.tryFirst" : "setup.openFile")
        secondary.target = self; secondary.action = mode == .install ? #selector(tryFirst) : #selector(chooseFile)
        secondary.bezelStyle = .rounded; secondary.controlSize = .large
        let actions = NSStackView(views: [primary, secondary]); actions.spacing = 12; actions.distribution = .fillEqually
        extra.title = localized("setup.returnToLino")
        extra.identifier = .init("setup.returnToLino")
        extra.target = self; extra.action = #selector(activateExisting)
        extra.isBordered = false; extra.font = .systemFont(ofSize: 12); extra.contentTintColor = .secondaryLabelColor
        extra.isHidden = true
        status.identifier = .init("setup-status"); status.alignment = .center; status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.stringValue = ""; status.setAccessibilityRole(.staticText)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        for view in [icon, title, subtitle, actions, extra, status, spinner] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 76), icon.heightAnchor.constraint(equalToConstant: 76), icon.centerXAnchor.constraint(equalTo: root.centerXAnchor), icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 46),
            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 18), title.centerXAnchor.constraint(equalTo: root.centerXAnchor), title.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 30), title.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -30),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10), subtitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 42), subtitle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -42),
            actions.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 30), actions.centerXAnchor.constraint(equalTo: root.centerXAnchor), actions.widthAnchor.constraint(equalToConstant: 388), primary.heightAnchor.constraint(equalToConstant: 38), secondary.heightAnchor.constraint(equalToConstant: 38),
            extra.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 15), extra.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            status.topAnchor.constraint(equalTo: extra.bottomAnchor, constant: 9), status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 38), status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -38),
            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor), spinner.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 18), spinner.widthAnchor.constraint(equalToConstant: 16), spinner.heightAnchor.constraint(equalToConstant: 16),
        ])
        window.initialFirstResponder = primary
        window.defaultButtonCell = primary.cell as? NSButtonCell
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !installing }
    func windowWillClose(_ notification: Notification) { if !acted { acted = true; finish() } }
    private func dismiss(_ action: () -> Void) { acted = true; close(); action() }
    func documentPresented() { if mode == .welcome { acted = true; close() } }
    @objc private func createDocument() {
        guard primary.isEnabled else { return }
        primary.isEnabled = false; secondary.isEnabled = false; spinner.startAnimation(nil)
        newDocument()
    }
    @objc private func chooseFile() { openFile() }
    @objc private func tryFirst() { dismiss(tryWithoutInstalling) }
    @objc private func activateExisting() {
        if let recoveryURL { NSWorkspace.shared.activateFileViewerSelecting([recoveryURL]) }
        else { installation.activateExistingApplication() }
    }
    @objc private func installApp() {
        guard !installing else { return }
        installing = true; primary.isEnabled = false; secondary.isEnabled = false; extra.isHidden = true
        window?.standardWindowButton(.closeButton)?.isEnabled = false
        primary.title = localized("setup.installing"); status.stringValue = ""; spinner.startAnimation(nil)
        Task { [weak self] in
            guard let self else { return }
            do { try await install(); acted = true; close() }
            catch {
                NSLog("Lino installation failed: %@", String(describing: error))
                if case ApplicationInstallationError.cannotRestore(let backup) = error {
                    recoveryURL = backup; extra.title = localized("setup.showBackup"); extra.isHidden = false
                    status.stringValue = localized("setup.restoreFailed")
                } else {
                    recoveryURL = nil; extra.title = localized("setup.returnToLino")
                    status.stringValue = localized((error as? ApplicationInstallationError) == .applicationRunning ? "setup.quitExisting" : "setup.installFailed")
                    extra.isHidden = installation.existingApplication == nil
                }
                status.textColor = .systemRed; primary.title = localized("setup.retryInstall")
            }
            installing = false; primary.isEnabled = true; secondary.isEnabled = true; spinner.stopAnimation(nil)
            window?.standardWindowButton(.closeButton)?.isEnabled = true
        }
    }
}
