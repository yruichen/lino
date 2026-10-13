import AppKit
import WebKit

@MainActor
func verifyLocalizationFlow(_ controller: EditorWindowController, settings: SettingsWindowController) async throws -> [String] {
    let bridge = controller.bridge
    func select(_ preference: InterfaceLanguage) async throws {
        guard let item = settings.languageControl.itemArray.first(where: { $0.representedObject as? String == preference.rawValue }) else {
            throw NSError(domain: "LocalizationVerification", code: 2)
        }
        settings.languageControl.select(item)
        settings.languageControl.sendAction(settings.languageControl.action, to: settings.languageControl.target)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while settings.applyingLanguage && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard !settings.applyingLanguage, settings.lastError == nil else {
            throw NSError(domain: "LocalizationVerification", code: 3, userInfo: [NSLocalizedDescriptionKey: settings.lastError ?? "Language action timed out"])
        }
    }
    var passed: [String] = []
    func check(_ name: String, _ condition: Bool) throws {
        guard condition else { throw NSError(domain: "LocalizationVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
        passed.append(name)
    }
    func snapshot() async throws -> [String: Any] { try await bridge.call("snapshot") as? [String: Any] ?? [:] }
    func stableState(_ state: [String: Any]) throws -> Data {
        var selected: [String: Any] = [:]
        for key in ["text", "selection", "mode", "canUndo", "canRedo", "dirty", "document"] { selected[key] = state[key] }
        return try JSONSerialization.data(withJSONObject: selected, options: [.sortedKeys])
    }
    try check("native-language-system-resolution", LanguagePreferences.resolve(.system, preferredLanguages: ["fr-FR", "zh-CN"]) == "zh-Hans"
        && LanguagePreferences.resolve(.system, preferredLanguages: ["de-DE", "en-GB"]) == "en"
        && LanguagePreferences.resolve(.english, preferredLanguages: ["zh-CN"]) == "en")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lino-language-verify-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let filename = "中文名称.md"
    let path = folder.appendingPathComponent(filename).path
    try Data("# 中文标题\n\n| A | B |\n| --- | --- |\n| 中 | 一 |\n".utf8).write(to: URL(fileURLWithPath: path))
    _ = try await bridge.call("prepareReplacement")
    let previous = try await bridge.call("replacementIntent", arguments: [true]) as? String
    let opened = try await bridge.backend.perform { try $0.openFile(path: path, replaceJson: previous) }
    _ = try await bridge.call("attachDocument", arguments: [opened])
    _ = try await bridge.call("verifyDocumentEdit")
    _ = try await bridge.call("checkpointDocument")
    let before = try await snapshot()
    let beforeState = try stableState(before)

    try await select(.english)
    let english = try await snapshot()
    try check("native-language-english-menus", NSApp.mainMenu?.items.contains { $0.submenu?.title == "File" } == true
        && controller.window?.toolbar?.items.first { $0.itemIdentifier == .editorFind }?.label == "Find")
    try check("native-language-english-web", english["locale"] as? String == "en")
    try check("native-language-keeps-document-and-history", try stableState(english) == beforeState && english["canUndo"] as? Bool == true)

    try await select(.simplifiedChinese)
    let chinese = try await snapshot()
    try check("native-language-chinese-menus", NSApp.mainMenu?.items.contains { $0.submenu?.title == "文件" } == true
        && controller.searchControls.item.label == "查找")
    try check("native-language-chinese-web", chinese["locale"] as? String == "zh-Hans")
    try check("native-language-keeps-filename", controller.window?.title == filename && (chinese["document"] as? [String: Any])?["label"] as? String == filename)
    try check("native-language-switch-is-not-edit", try stableState(chinese) == beforeState)
    _ = try await bridge.call("command", arguments: ["undo"])
    let undone = try await snapshot()
    _ = try await bridge.call("command", arguments: ["redo"])
    let redone = try await snapshot()
    try check("native-language-existing-undo-redo", undone["text"] as? String != before["text"] as? String && redone["text"] as? String == before["text"] as? String)

    // Rebuild only this isolated fixture, after an explicit flush/durability
    // barrier. Production language changes above never reload the editor.
    _ = try await bridge.call("checkpointDocument")
    _ = try await bridge.call("prepareReplacement")
    let accepted = try await snapshot()
    let oldReady = bridge.onReady
    var ready = false
    var reconnectError: Error?
    bridge.onReady = {
        Task {
            do { try await controller.documents.initialize(); ready = true }
            catch { reconnectError = error }
        }
    }
    defer { bridge.onReady = oldReady }
    controller.documents.viewTerminated()
    try controller.loadEditor()
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while !ready && reconnectError == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
    if let reconnectError { throw reconnectError }
    try check("native-language-reconnect-ready", ready)
    let reconnected = try await snapshot()
    let injected = try await controller.webView.callAsyncJavaScript("return window.__linoLocale", arguments: [:], in: nil, contentWorld: .page)
    try check("native-language-reconnect-retains-choice", reconnected["locale"] as? String == "zh-Hans" && injected as? String == "zh-Hans"
        && LanguagePreferences.shared.preference == .simplifiedChinese)
    try check("native-language-reconnect-retains-source", reconnected["text"] as? String == accepted["text"] as? String
        && controller.window?.title == filename)

    _ = try await bridge.call("prepareReplacement")
    let discard = try await bridge.call("replacementIntent", arguments: [true]) as? String
    let clean = try await bridge.backend.perform { try $0.newDocument(replaceJson: discard) }
    _ = try await bridge.call("attachDocument", arguments: [clean])
    try await select(.system)
    try check("native-language-system-memory-preference", LanguagePreferences.shared.preference == .system && LanguagePreferences.shared.locale == "en")
    return passed
}
