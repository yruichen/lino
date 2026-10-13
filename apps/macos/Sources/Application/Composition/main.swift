import AppKit
import WebKit

@MainActor
final class EditorApplication: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    weak var recentMenu: NSMenu?
    private let windows = DocumentWindows()
    private var currentController: EditorWindowController? { verifying ? controller : windows.active }
    private var controller: EditorWindowController?
    private var settingsController: SettingsWindowController?
    private var finished = false
    private var verificationStage = "startup"
    private var changingLanguage = false
    private var starting = true
    private var pendingOpenPaths: [String] = []
    private lazy var preferences = PreferencesCoordinator(backend: windows.backend)
    private var verificationLifecycle: [String] = []
    private let verifying = CommandLine.arguments.contains("--verify")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await start() }
    }
    private func start() async {
        LanguagePreferences.shared.configure(verifying: verifying)
        var startupError: String?
        do { try await preferences.configure(verifying: verifying) }
        catch {
            if verifying { finish(["failed": [error.localizedDescription]], code: 1); return }
            startupError = error.localizedDescription
        }
        applyNativePreferences()
        if preferences.snapshot?.storage_warning != nil { startupError = localized("settings.notDurable") }
        starting = false
        if !verifying {
            installEditorMenus(target: self)
            let paths = pendingOpenPaths.isEmpty ? windows.restorationPaths : pendingOpenPaths
            pendingOpenPaths = []
            let first = windows.create(path: paths.first, offerRecovery: paths.isEmpty)
            if let startupError { first.showError(startupError) }
            for path in paths.dropFirst() { Task { await windows.open(path: path) } }
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = EditorWindowController(verifying: verifying, backend: windows.backend)
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
                    else { controller.bridge.onError?(error.localizedDescription) }
                }
            }
        }
        if verifying {
            controller.bridge.onError = { [weak self] message in self?.finish(["failed": [message]], code: 1) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
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
                        let recoveryChecks = try await verifyRecoveryFlow(bridge: bridge)
                        report["passed"] = (report["passed"] as? [String] ?? []) + recoveryChecks
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
        if code == 0 { preferences.cleanupVerificationFiles() }
        exit(code)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
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
    func applicationWillTerminate(_ notification: Notification) { controller?.detach(); windows.detach() }
    func setInterfaceLanguage(_ preference: InterfaceLanguage) async throws {
        guard var values = preferences.snapshot?.values else { return }
        values.language = preference.rawValue
        try await setPreferences(values)
    }
    private func applyNativePreferences() {
        guard let values = preferences.snapshot?.values else { return }
        LanguagePreferences.shared.select(InterfaceLanguage(rawValue: values.language) ?? .system)
        NSApp.appearance = values.theme == "system" ? nil : NSAppearance(named: values.theme == "dark" ? .darkAqua : .aqua)
    }
    private func setPreferences(_ values: EditorPreferences) async throws {
        guard !changingLanguage, !windows.quitting, !(verifying ? [controller].compactMap({ $0 }) : windows.controllers).contains(where: { $0.documents.busy }) else {
            throw NSError(domain: "Lino", code: 4, userInfo: [NSLocalizedDescriptionKey: localized("error.languageBusy")])
        }
        changingLanguage = true; defer { changingLanguage = false }
        let snapshot = try await preferences.update(values)
        applyNativePreferences()
        installEditorMenus(target: self)
        for document in verifying ? [controller].compactMap({ $0 }) : windows.controllers { document.relocalize() }
        settingsController?.relocalize()
        var errors: [String] = []
        for document in verifying ? [controller].compactMap({ $0 }) : windows.controllers where document.documents.ready {
            do {
                _ = try await document.bridge.call("setLocale", arguments: [LanguagePreferences.shared.locale])
                try await document.documents.applyPreferences(snapshot.json())
            } catch { errors.append(error.localizedDescription) }
        }
        if snapshot.storage_warning != nil { errors.append(localized("settings.notDurable")) }
        if !errors.isEmpty { throw NSError(domain: "Lino", code: 4, userInfo: [NSLocalizedDescriptionKey: localized("error.languageApply", errors.joined(separator: " · "))]) }
    }
    func settingsWindow() -> SettingsWindowController {
        if let settingsController { return settingsController }
        let settings = SettingsWindowController(selectLanguage: { [weak self] preference in
            guard let self else { return }
            try await setInterfaceLanguage(preference)
        }, values: { [weak self] in self?.preferences.snapshot?.values }, apply: { [weak self] values in try await self?.setPreferences(values) })
        settingsController = settings
        return settings
    }
    @objc func showSettings() { settingsWindow().showWindow(nil) }
    private var documentForAction: EditorWindowController? {
        guard let controller = currentController, controller.isActiveDocument, controller.documents.ready, !controller.documents.busy else { return nil }
        return controller
    }
    @objc func newDocument() { if verifying { Task { await controller?.documents.replace(open: false) } } else if !windows.quitting { windows.create() } }
    @objc func openDocument() { if verifying { Task { await controller?.documents.replace(open: true) } } else { Task { await windows.openDialog() } } }
    @objc func openFolder() { let document = currentController ?? windows.create(); Task { await document.workspace.chooseRoot() } }
    @objc func toggleWorkspace() { currentController?.toggleWorkspace() }
    @objc func quickOpen() { currentController?.workspace.quickOpen() }
    @objc func searchWorkspace() { currentController?.workspace.searchWorkspace() }
    @objc func cancelWorkspaceSearch() { currentController?.workspace.cancelSearch() }
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
    @objc func reloadDocument() { guard let controller = documentForAction else { return }; Task { await controller.documents.reloadFile() } }
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
            do { try await setPreferences(values) } catch { controller.showError(error.localizedDescription) }
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
        if [#selector(exportHTML), #selector(exportPDF), #selector(printDocument), #selector(pageSetup)].contains(menuItem.action) { return documentForAction != nil && currentController?.exports.busy == false }
        if menuItem.action == #selector(cancelExport) { return currentController?.exports.cancellable == true }
        if menuItem.action == #selector(reloadDocument) { return documentForAction?.documents.hasFile == true }
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
application.setActivationPolicy(CommandLine.arguments.contains("--verify") ? .accessory : .regular)
let delegate = EditorApplication()
application.delegate = delegate
application.run()
