import AppKit
import WebKit

@MainActor
final class EditorApplication: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var controller: EditorWindowController?
    private var settingsController: SettingsWindowController?
    private var finished = false
    private var verificationStage = "startup"
    private var changingLanguage = false
    private var verificationLifecycle: [String] = []
    private let verifying = CommandLine.arguments.contains("--verify")

    func applicationDidFinishLaunching(_ notification: Notification) {
        LanguagePreferences.shared.configure(verifying: verifying)
        let controller = EditorWindowController(verifying: verifying)
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
        controller?.bridge.command("source") { [weak self] accepted in
            guard accepted else { self?.finish(["failed": ["Native command was not accepted"]], code: 1); return }
            self?.verifyView()
        }
    }

    private func verifyView() {
        controller?.webView.callAsyncJavaScript("if (window.openTypora.snapshot().mode !== 'source') return {failed: ['Native command did not reach the engine']}; const report = await window.openTypora.verify(); report.passed.push('native-command-routing'); return report", arguments: [:], in: nil, in: .page) { [weak self] result in
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
        exit(code)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if verifying { verificationLifecycle.append("last-window-closed:\(verificationStage)") }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if verifying { verificationLifecycle.append("termination-request:\(verificationStage)") }
        guard let controller, !controller.documents.closed else { return .terminateNow }
        Task { NSApp.reply(toApplicationShouldTerminate: await controller.documents.close()) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { controller?.detach() }
    func setInterfaceLanguage(_ preference: InterfaceLanguage) async throws {
        guard !changingLanguage, controller?.documents.busy != true else {
            throw NSError(domain: "OpenTypora", code: 4, userInfo: [NSLocalizedDescriptionKey: localized("error.languageBusy")])
        }
        changingLanguage = true; defer { changingLanguage = false }
        LanguagePreferences.shared.select(preference)
        installEditorMenus(target: self)
        controller?.relocalize()
        settingsController?.relocalize()
        if controller?.documents.ready == true {
            do { _ = try await controller?.bridge.call("setLocale", arguments: [LanguagePreferences.shared.locale]) }
            catch {
                throw NSError(domain: "OpenTypora", code: 4, userInfo: [NSLocalizedDescriptionKey: localized("error.languageApply", error.localizedDescription)])
            }
        }
    }
    func settingsWindow() -> SettingsWindowController {
        if let settingsController { return settingsController }
        let settings = SettingsWindowController { [weak self] preference in
            guard let self else { return }
            try await setInterfaceLanguage(preference)
        }
        settingsController = settings
        return settings
    }
    @objc func showSettings() { settingsWindow().showWindow(nil) }
    private var documentForAction: EditorWindowController? {
        guard let controller, controller.isActiveDocument, controller.documents.ready, !controller.documents.busy else { return nil }
        return controller
    }
    @objc func newDocument() { guard let controller = documentForAction else { return }; Task { await controller.documents.replace(open: false) } }
    @objc func openDocument() { guard let controller = documentForAction else { return }; Task { await controller.documents.replace(open: true) } }
    @objc func saveDocument() { guard let controller = documentForAction else { return }; Task { await controller.documents.save() } }
    @objc func saveDocumentAs() { guard let controller = documentForAction else { return }; Task { await controller.documents.save(asNew: true) } }
    @objc func toggleAutosave() { guard let controller = documentForAction else { return }; Task { await controller.documents.toggleAutosave() } }
    @objc func restoreDocument() { guard let controller = documentForAction else { return }; Task { await controller.documents.restoreDraft() } }
    @objc func retryPersistence() { guard let controller = documentForAction else { return }; Task { await controller.documents.retryPersistence() } }
    @objc func reconnectEditor() { if controller?.isActiveDocument == true { controller?.reconnect() } }
    @objc func editorCommand(_ sender: NSMenuItem) {
        if let command = sender.representedObject as? String, controller?.allowsCommand(command) == true { controller?.bridge.command(command) }
    }
    @objc func undoEdit() { if controller?.allowsCommand("undo") == true, controller?.canUndo == true { controller?.bridge.command("undo") } }
    @objc func redoEdit() { if controller?.allowsCommand("redo") == true, controller?.canRedo == true { controller?.bridge.command("redo") } }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undoEdit) { return controller?.allowsCommand("undo") == true && controller?.canUndo == true }
        if menuItem.action == #selector(redoEdit) { return controller?.allowsCommand("redo") == true && controller?.canRedo == true }
        if menuItem.action == #selector(toggleAutosave) { menuItem.state = controller?.documents.autosave == true ? .on : .off }
        if menuItem.action == #selector(reconnectEditor) { return controller?.isActiveDocument == true && controller?.documents.ready == false && controller?.documents.busy == false }
        if menuItem.action == #selector(editorCommand(_:)) {
            guard let command = menuItem.representedObject as? String else { return false }
            if command == "toggle-source" { menuItem.state = controller?.modeControl.selectedSegment == 1 ? .on : .off }
            return controller?.allowsCommand(command) == true
        }
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
