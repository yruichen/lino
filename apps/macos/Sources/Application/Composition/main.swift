import AppKit
import WebKit

@MainActor
final class EditorApplication: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    weak var recentMenu: NSMenu?
    private let windows = DocumentWindows(verifying: CommandLine.arguments.contains("--verify") || CommandLine.arguments.contains("--verify-navigation") || CommandLine.arguments.contains("--verify-settings"))
    private var currentController: EditorWindowController? { verifying ? controller : windows.active }
    private var controller: EditorWindowController?
    private var settingsController: SettingsWindowController?
    private var setupController: SetupWindowController?
    private var finished = false
    private var verificationStage = "startup"
    private var changingLanguage = false
    private var starting = true
    private var pendingOpenPaths: [String] = []
    private lazy var preferences = PreferencesCoordinator(backend: windows.backend)
    private lazy var updates = UpdateCoordinator(backend: windows.backend, defaults: verifying ? nil : .standard)
    private var verificationLifecycle: [String] = []
    private let verifying = CommandLine.arguments.contains("--verify") || CommandLine.arguments.contains("--verify-navigation") || CommandLine.arguments.contains("--verify-settings")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await start() }
    }
    private func start() async {
        LanguagePreferences.shared.configure(verifying: verifying)
        var startupError: String?
        do { try await preferences.configure(verifying: verifying); try await windows.navigation.configure(verifying: verifying) }
        catch {
            if verifying { finish(["failed": [error.localizedDescription]], code: 1); return }
            startupError = userFacingError(error)
        }
        windows.navigation.onError = { [weak self] message in self?.currentController?.showError(message) }
        applyNativePreferences()
        if let values = preferences.snapshot?.values { updates.configure(values) }
        if preferences.snapshot?.storage_warning != nil { startupError = localized("settings.notDurable") }
        starting = false
        if !verifying {
            installEditorMenus(target: self)
            let paths = pendingOpenPaths.isEmpty ? windows.restorationPaths : pendingOpenPaths
            pendingOpenPaths = []
            if paths.isEmpty { windows.create(offerRecovery: true) }
            else { for path in paths { await windows.open(path: path) } }
            if let startupError { windows.controllers.first?.showError(startupError) }
            NSApp.activate(ignoringOtherApps: true)
            updates.checkAutomatically()
            if paths.isEmpty, !UserDefaults.standard.bool(forKey: "setup.hasSeenWelcome") { showSetup() }
            return
        }
        let controller = EditorWindowController(verifying: verifying, backend: windows.backend, navigation: windows.navigation)
        self.controller = controller
        controller.onClosed = { [weak self] in self?.settingsController?.close() }
        installEditorMenus(target: self)
        controller.bridge.onReady = { [weak self, weak controller] in
            Task {
                guard let self, let controller else { return }
                do {
                    self.verificationStage = "initialization"
                    try await controller.documents.initialize()
                    if self.verifying { self.verify() }
                } catch {
                    if self.verifying { self.finish(["failed": [error.localizedDescription]], code: 1) }
                    else { controller.bridge.onError?(userFacingError(error)) }
                }
            }
        }
        if verifying {
            controller.bridge.onError = { [weak self] message in self?.finish(["failed": [message]], code: 1) }
            DispatchQueue.main.asyncAfter(deadline: .now() + (CommandLine.arguments.contains("--focused") ? 75 : 30)) { [weak self] in
                self?.finish(["failed": ["WKWebView validation timed out"]], code: 1)
            }
        } else {
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        do { try controller.loadEditor() }
        catch { finish(["failed": [error.localizedDescription]], code: 1) }
    }

    private func verify() {
        if CommandLine.arguments.contains("--verify-settings"), let controller {
            verificationStage = "settings"
            Task {
                do { let checks = try await verifySettingsFlow(controller, settings: settingsWindow(), values: { self.preferences.snapshot?.values }, navigation: windows.navigation); finish(["passed": checks, "failed": []], code: 0) }
                catch { finish(["failed": [String(describing: error)]], code: 1) }
            }
            return
        }
        if CommandLine.arguments.contains("--verify-navigation"), let controller {
            verificationStage = "navigation"
            let focused = CommandLine.arguments.contains("--focused")
            if focused && !CommandLine.arguments.contains("--headless") { controller.showWindow(nil); NSApp.activate(ignoringOtherApps: true) }
            Task {
                var checks: [String] = [], failures: [String] = []
                let requested = CommandLine.arguments.first { $0.hasPrefix("--stage=") || $0.hasPrefix("--stages=") }.map { Set($0.split(separator: "=", maxSplits: 1)[1].split(separator: ",").map(String.init)) }
                @MainActor func run(_ stage: String, _ action: @MainActor () async throws -> [String]) async {
                    guard requested == nil || requested?.contains(stage) == true else { return }
                    self.verificationStage = stage
                    if CommandLine.arguments.contains("--headless") { FileHandle.standardError.write(Data(("stage: " + stage + "\n").utf8)) }
                    do { checks += try await action() }
                    catch { failures.append("\(stage): \(String(describing: error))") }
                }
                await run("navigation") {
                    if focused || CommandLine.arguments.contains("--presentation-only") { return try await verifyNavigationPresentation(self.windows) }
                    return try await verifyNavigationFlow(controller, navigation: self.windows.navigation)
                }
                if focused {
                    await run("interface") { try await verifyInterface(controller) }
                    await run("upgrade") { try await verifyUpgrade(self.windows) }
                    await run("media-output") { try await verifyMediaOutput(self.windows) }
                    await run("appearance") { try await verifyAppearanceControls(controller, settings: self.settingsWindow(), values: { self.preferences.snapshot?.values }) }
                    await run("image-references") { try await verifyImageReferenceInsertion(self.windows) }
                    await run("window-chrome") {
                        let root = controller.window!.contentView!, guide = controller.window!.contentLayoutGuide as! NSLayoutGuide
                        let nativeToolbar = controller.window!.styleMask.contains(.fullSizeContentView) && controller.window!.titlebarAppearsTransparent && controller.searchControls.item.isBordered && guide.frame.maxY < root.bounds.maxY
                        guard nativeToolbar else { throw NSError(domain: "WindowChromeVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: "Native translucent toolbar or safe content layout was missing"]) }
                        return ["native-translucent-toolbar-keeps-controls-and-writing-below-titlebar"]
                    }
                }
                finish(["passed": checks, "failed": failures], code: failures.isEmpty ? 0 : 1)
            }
            return
        }
        verificationStage = "editor-fixtures"
        currentController?.bridge.command("source") { [weak self] accepted in
            guard accepted else { self?.finish(["failed": ["Native command was not accepted"]], code: 1); return }
            self?.verifyView()
        }
    }

    private func verifyView() {
        controller?.webView.callAsyncJavaScript("if (window.lino.snapshot().mode !== 'source') return {failed: ['Native command did not reach the engine']}; const report = await window.lino.verify(); report.passed.push('native-command-routing'); return report", arguments: [:], in: nil, in: .page) { [weak self] result in
            switch result {
            case .success(let value):
                guard let self, let controller = self.controller else { return }
                let bridge = controller.bridge
                let viewReport = value as? [String: Any] ?? ["failed": ["Invalid editor report"]]
                Task {
                    var report = viewReport
                    do {
                        self.verificationStage = "window"
                        let surfaceChecks = try verifyInitialEditorSurface()
                        report["passed"] = (report["passed"] as? [String] ?? []) + surfaceChecks
                        let windowChecks = try await verifyWindowLayout(controller)
                        report["passed"] = (report["passed"] as? [String] ?? []) + windowChecks
                        self.verificationStage = "commands"
                        let commandChecks = try await verifyCommandFlow(controller, settings: self.settingsWindow())
                        report["passed"] = (report["passed"] as? [String] ?? []) + commandChecks
                        self.verificationStage = "document"
                        let documentChecks = try await verifyDocumentFlow(bridge: bridge)
                        report["passed"] = (report["passed"] as? [String] ?? []) + documentChecks
                        self.verificationStage = "recovery"
                        let recoveryChecks = try await verifyRecoveryFlow(bridge: bridge, onStep: { self.verificationStage = "recovery:" + $0 })
                        report["passed"] = (report["passed"] as? [String] ?? []) + recoveryChecks
                        self.verificationStage = "navigation"
                        let navigationChecks = try await verifyNavigationFlow(controller, navigation: windows.navigation)
                        report["passed"] = (report["passed"] as? [String] ?? []) + navigationChecks
                        self.verificationStage = "localization"
                        let localizationChecks = try await verifyLocalizationFlow(controller, settings: self.settingsWindow())
                        report["passed"] = (report["passed"] as? [String] ?? []) + localizationChecks
                    } catch { report["failed"] = (report["failed"] as? [String] ?? []) + [error.localizedDescription] }
                    self.finish(report, code: (report["failed"] as? [String])?.isEmpty == true ? 0 : 1)
                }
            case .failure(let error): self?.finish(["failed": [error.localizedDescription]], code: 1)
            }
        }
    }

    private func finish(_ report: [String: Any], code: Int32) {
        guard !finished else { return }
        finished = true
        var report = report
        if !verificationLifecycle.isEmpty { report["nativeLifecycle"] = verificationLifecycle }
        if code != 0 { report["verificationStage"] = verificationStage }
        if code != 0, let directory = controller?.documents.verificationRecoveryPath { report["recoveryDirectory"] = directory }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
        controller?.detach()
        if code == 0 { controller?.documents.cleanupVerificationFiles() }
        if code == 0 { preferences.cleanupVerificationFiles(); windows.navigation.detach() }
        exit(code)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if CommandLine.arguments.contains("--headless") { return false }
        if verifying { verificationLifecycle.append("last-window-closed:\(verificationStage)") }
        return verifying
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if verifying { verificationLifecycle.append("termination-request:\(verificationStage)") }
        if !verifying { Task { NSApp.reply(toApplicationShouldTerminate: await windows.terminate()) }; return .terminateLater }
        guard let controller, !controller.documents.closed else { return .terminateNow }
        Task { NSApp.reply(toApplicationShouldTerminate: await controller.documents.close()) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { updates.cancel(); controller?.detach(); windows.detach() }
    func applicationDidBecomeActive(_ notification: Notification) { if !verifying, !starting { updates.checkAutomatically() } }
    func setInterfaceLanguage(_ preference: InterfaceLanguage) async throws {
        guard var values = preferences.snapshot?.values else { return }
        values.language = preference.rawValue
        try await setPreferences(values)
    }
    private func applyNativePreferences() {
        guard let values = preferences.snapshot?.values else { return }
        LanguagePreferences.shared.select(InterfaceLanguage(rawValue: values.language) ?? .system)
        NSApp.appearance = values.theme == "system" ? nil : NSAppearance(named: values.theme == "dark" ? .darkAqua : .aqua)
        ThemePalette.install(values)
    }
    private func setPreferences(_ values: EditorPreferences) async throws {
        guard !changingLanguage, !windows.quitting, !(verifying ? [controller].compactMap({ $0 }) : windows.controllers).contains(where: { $0.documents.busy }) else {
            throw NSError(domain: "Lino", code: 4, userInfo: [NSLocalizedDescriptionKey: localized("error.languageBusy")])
        }
        changingLanguage = true; defer { changingLanguage = false }
        let snapshot = try await preferences.update(values)
        updates.configure(snapshot.values)
        if !verifying { updates.checkAutomatically() }
        applyNativePreferences()
        installEditorMenus(target: self)
        for document in verifying ? [controller].compactMap({ $0 }) : windows.controllers { document.relocalize() }
        settingsController?.relocalize()
        setupController?.relocalize()
        var errors: [String] = []
        for document in verifying ? [controller].compactMap({ $0 }) : windows.controllers where document.documents.ready {
            do {
                _ = try await document.bridge.call("setLocale", arguments: [LanguagePreferences.shared.locale])
                try await document.documents.applyPreferences(snapshot.json())
            } catch { errors.append(userFacingError(error)) }
        }
        if snapshot.storage_warning != nil { errors.append(localized("settings.notDurable")) }
        if !errors.isEmpty { throw NSError(domain: "Lino", code: 4, userInfo: [NSLocalizedDescriptionKey: localized("error.languageApply", errors.joined(separator: " · "))]) }
    }
    func settingsWindow() -> SettingsWindowController {
        if let settingsController { return settingsController }
        let settings = SettingsWindowController(selectLanguage: { [weak self] preference in
            guard let self else { return }
            try await setInterfaceLanguage(preference)
        }, values: { [weak self] in self?.preferences.snapshot?.values }, apply: { [weak self] values in try await self?.setPreferences(values) }, navigation: windows.navigation, updates: updates)
        settingsController = settings
        return settings
    }
    @objc func showSetup() {
        if setupController == nil {
            setupController = SetupWindowController(openFile: { [weak self] in self?.openDocument() }, openFolder: { [weak self] in self?.openFolder() })
        }
        if !verifying { UserDefaults.standard.set(true, forKey: "setup.hasSeenWelcome") }
        setupController?.relocalize(); setupController?.showWindow(nil)
    }
    @objc func showSettings() { settingsWindow().showWindow(nil) }
    @objc func checkForUpdates() { let settings = settingsWindow(); settings.selectCategory("updates"); settings.showWindow(nil); updates.check() }
    private var documentForAction: EditorWindowController? {
        guard let controller = currentController, !controller.isPreviewing, controller.isActiveDocument, controller.documents.ready, !controller.documents.busy else { return nil }
        return controller
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !starting, !windows.quitting else { return true }
        if !flag { windows.reopen() }
        return true
    }
    @objc func newDocument() { if verifying { Task { await controller?.documents.replace(open: false) } } else if !windows.quitting { windows.create() } }
    @objc func openDocument() { if verifying { Task { await controller?.documents.replace(open: true) } } else { Task { await windows.openDialog() } } }
    @objc func openFolder() { let document = currentController ?? windows.create(); Task { await document.workspace.chooseRoot() } }
    @objc func toggleWorkspace() { currentController?.toggleWorkspace() }
    @objc func quickOpen() { currentController?.workspace.quickOpen() }
    @objc func searchWorkspace() { currentController?.workspace.searchWorkspace() }
    @objc func cancelWorkspaceSearch() { currentController?.quickOpen.dismiss() }
    @objc func customizeSidebar() { currentController?.showSidebarCustomization() }
    @objc func sidebarOption(_ item: NSMenuItem) {
        guard let key = item.representedObject as? String else { return }
        Task { await windows.navigation.change { values in
            switch key {
            case "favorites": values.show_favorites.toggle()
            case "locations": values.show_locations.toggle()
            case "recents": values.show_recents.toggle()
            case "follow": values.follow_active.toggle()
            case "name": values.sort = "name"
            case "modified": values.sort = "modified"
            default: break
            }
        } }
    }
    @objc func reopenClosed() { Task { await windows.reopenClosed() } }
    @objc func saveAll() { Task { await windows.saveAll() } }
    @objc func openRecent(_ sender: NSMenuItem) { if let path = sender.representedObject as? String { Task { await windows.open(path: path) } } }
    @objc func clearRecent() { NSDocumentController.shared.clearRecentDocuments(nil); installEditorMenus(target: self) }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        for url in (verifying ? [] : NSDocumentController.shared.recentDocumentURLs).prefix(20) {
            let item = menu.addItem(withTitle: url.path, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = url.path
        }
        menu.addItem(.separator())
        let clear = menu.addItem(withTitle: localized("workspace.clearRecent"), action: #selector(clearRecent), keyEquivalent: ""); clear.target = self
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if starting { pendingOpenPaths.append(contentsOf: filenames) }
        else { for path in filenames { Task { await windows.open(path: path) } } }
        sender.reply(toOpenOrPrint: .success)
    }
    @objc func saveDocument() { guard let controller = documentForAction else { return }; Task { await controller.documents.save() } }
    @objc func saveDocumentAs() { guard let controller = documentForAction else { return }; Task { await controller.documents.save(asNew: true) } }
    @objc func reloadDocument() {
        if let controller = currentController, let preview = controller.filePreview {
            do { try preview.reload() } catch { controller.showError(userFacingError(error)) }; return
        }
        guard let controller = documentForAction else { return }; Task { await controller.documents.reloadFile() }
    }
    @objc func toggleReadOnly() { guard let controller = documentForAction else { return }; Task { await controller.documents.toggleReadOnly() } }
    @objc func exportHTML() { guard let controller = documentForAction else { return }; Task { await controller.exports.export(.html, label: controller.documents.label) } }
    @objc func exportPDF() { guard let controller = documentForAction else { return }; Task { await controller.exports.export(.pdf, label: controller.documents.label) } }
    @objc func printDocument() { guard let controller = documentForAction else { return }; Task { await controller.exports.export(.printDocument, label: controller.documents.label) } }
    @objc func pageSetup() { currentController?.exports.pageSetup() }
    @objc func cancelExport() { currentController?.exports.cancel() }
    @objc func toggleAutosave() {
        guard let controller = documentForAction else { return }
        if verifying { Task { await controller.documents.toggleAutosave() } }
        else { Task {
            guard var values = preferences.snapshot?.values else { return }
            values.auto_save.toggle()
            do { try await setPreferences(values) } catch { controller.showError(userFacingError(error)) }
        } }
    }
    @objc func restoreDocument() { guard let controller = documentForAction else { return }; Task { await controller.documents.restoreDraft() } }
    @objc func retryPersistence() { guard let controller = documentForAction else { return }; Task { await controller.documents.retryPersistence() } }
    @objc func reconnectEditor() { if currentController?.isActiveDocument == true { currentController?.reconnect() } }
    @objc func editorCommand(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? String, currentController?.allowsCommand(command) == true { currentController?.performEditorCommand(command) }
    }
    @objc func undoEdit() { if currentController?.allowsCommand("undo") == true, currentController?.canUndo == true { currentController?.bridge.command("undo") } }
    @objc func redoEdit() { if currentController?.allowsCommand("redo") == true, currentController?.canRedo == true { currentController?.bridge.command("redo") } }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(sidebarOption(_:)), let key = menuItem.representedObject as? String {
            let values = windows.navigation.values
            let selected = ["favorites": values.show_favorites, "locations": values.show_locations, "recents": values.show_recents, "follow": values.follow_active, "name": values.sort == "name", "modified": values.sort == "modified"]
            menuItem.state = selected[key] == true ? .on : .off; return true
        }
        if menuItem.action == #selector(toggleWorkspace) { menuItem.state = currentController?.workspaceVisible == true ? .on : .off }

        if [#selector(exportHTML), #selector(exportPDF), #selector(printDocument), #selector(pageSetup)].contains(menuItem.action) { return documentForAction != nil && currentController?.exports.busy == false }
        if menuItem.action == #selector(cancelExport) { return currentController?.exports.cancellable == true }
        if menuItem.action == #selector(reloadDocument) { return currentController?.isPreviewing == true || documentForAction?.documents.hasFile == true }
        if menuItem.action == #selector(toggleReadOnly) {
            menuItem.state = currentController?.documents.readOnly == true ? .on : .off
            return documentForAction != nil
        }
        if menuItem.action == #selector(undoEdit) { return currentController?.allowsCommand("undo") == true && currentController?.canUndo == true }
        if menuItem.action == #selector(redoEdit) { return currentController?.allowsCommand("redo") == true && currentController?.canRedo == true }
        if menuItem.action == #selector(toggleAutosave) {
            menuItem.state = currentController?.documents.autosave == true ? .on : .off
            if changingLanguage { return false }
        }
        if menuItem.action == #selector(reconnectEditor) { return currentController?.isActiveDocument == true && currentController?.documents.ready == false && currentController?.documents.busy == false }
        if menuItem.action == #selector(editorCommand(_:)) {
            guard let command = menuItem.representedObject as? String else { return false }
            menuItem.state = currentController?.writingMenuState(command) ?? .off
            if command == "toggle-source" { menuItem.state = currentController?.editorMode == "source" ? .on : .off }
            return currentController?.allowsCommand(command) == true
        }
        if [#selector(newDocument), #selector(openDocument)].contains(menuItem.action) { return !windows.quitting }
        if [#selector(toggleWorkspace), #selector(quickOpen), #selector(searchWorkspace), #selector(cancelWorkspaceSearch)].contains(menuItem.action) { return currentController != nil && !windows.quitting }
        if menuItem.action == #selector(saveAll) { return !windows.quitting && !windows.controllers.isEmpty }
        if [#selector(newDocument), #selector(openDocument), #selector(saveDocument), #selector(saveDocumentAs), #selector(toggleAutosave), #selector(restoreDocument), #selector(retryPersistence)].contains(menuItem.action) {
            return documentForAction != nil
        }
        return true
    }
}

let application = NSApplication.shared
application.setActivationPolicy(CommandLine.arguments.contains("--headless") ? .prohibited : CommandLine.arguments.contains("--verify") || CommandLine.arguments.contains("--verify-navigation") || CommandLine.arguments.contains("--verify-settings") ? .accessory : .regular)
let delegate = EditorApplication()
application.delegate = delegate
application.run()
