import Foundation

@MainActor
func verifyDocumentFlow(bridge: EditorBridge) async throws -> [String] {
    var passed: [String] = []
    var step = "start"
    do {
    func check(_ name: String, _ condition: Bool) throws {
        if !condition { throw NSError(domain: "DocumentVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
        passed.append(name)
        step = "after-" + name
    }
    func snapshot() async throws -> [String: Any] { try await bridge.call("snapshot") as? [String: Any] ?? [:] }
    func intent(_ discard: Bool = false) async throws -> String {
        _ = try await bridge.call("prepareReplacement")
        guard let json = try await bridge.call("replacementIntent", arguments: [discard]) as? String else { throw NSError(domain: "DocumentVerification", code: 2) }
        return json
    }
    func attach(_ json: String) async throws {
        _ = try await bridge.call("attachDocument", arguments: [json])
        _ = try await bridge.call("cancelReplacement")
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lino-verify-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("中文.md").path
    let raw = "# 标题\r\n\r\n| A | B |\r\n| --- | --- |\r\n| 中 | 一 |\r\n\n尾👩🏽‍💻\r"
    let bom = Data([0xef, 0xbb, 0xbf])
    try (bom + Data(raw.utf8)).write(to: URL(fileURLWithPath: path))
    let old = try await intent()
    let opened = try await bridge.backend.perform { try $0.openFile(path: path, replaceJson: old) }
    try await attach(opened)
    try check("rust-wk-open-mixed-endings", try await snapshot()["text"] as? String == raw)
    let edited = try await bridge.call("verifyDocumentEdit") as? String
    let expected = "新🙂\r\n" + raw.replacingOccurrences(of: "| 中 | 一 |", with: "| 中 | 二🙂 |")
    try check("rust-wk-table-edit-source", edited == expected)
    _ = try await bridge.call("saveDocument")
    try check("rust-wk-save-byte-exact-bom", try Data(contentsOf: URL(fileURLWithPath: path)) == bom + Data(expected.utf8))
    try check("rust-wk-save-clears-only-saved-state", try await snapshot()["dirty"] as? Bool == false)
    let closing = try await intent()
    _ = try await bridge.call("closeDocument", arguments: [closing])
    let reopened = try await bridge.backend.perform { try $0.openFile(path: path, replaceJson: nil) }
    try await attach(reopened)
    let restored = try await snapshot()
    try check("rust-wk-close-reopen-text", restored["text"] as? String == expected)
    try check("rust-wk-new-session-history", restored["canUndo"] as? Bool == false)
    let local = try await bridge.call("verifyDocumentEdit") as? String
    try Data("outside\n".utf8).write(to: URL(fileURLWithPath: path))
    var conflict = false
    do { _ = try await bridge.call("saveDocument") } catch { conflict = true }
    try check("rust-wk-conflict-keeps-external-bytes", conflict && (try String(contentsOfFile: path, encoding: .utf8)) == "outside\n")
    let retained = try await snapshot()
    try check("rust-wk-conflict-keeps-local-dirty", retained["text"] as? String == local && retained["dirty"] as? Bool == true)
    let invalid = folder.appendingPathComponent("invalid.md").path
    try Data([0xff]).write(to: URL(fileURLWithPath: invalid))
    let discard = try await intent(true)
    var rejected = false
    do { _ = try await bridge.backend.perform { try $0.openFile(path: invalid, replaceJson: discard) } } catch { rejected = true }
    _ = try await bridge.call("cancelReplacement")
    let afterFailedOpen = try await snapshot()
    try check("rust-wk-failed-open-keeps-old-session", rejected && afterFailedOpen["text"] as? String == local)
    // A real readonly target must fail without changing the local or disk source.
    let readonly = folder.appendingPathComponent("readonly.md").path
    try Data("readonly".utf8).write(to: URL(fileURLWithPath: readonly))
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readonly)
    let deniedTarget = try await bridge.backend.perform { try $0.saveTarget(path: readonly) }
    var denied = false
    do { _ = try await bridge.call("saveDocument", arguments: [deniedTarget]) } catch { denied = true }
    try await bridge.backend.perform { try $0.releaseSaveTarget(targetJson: deniedTarget) }
    try check("rust-wk-denied-save-keeps-disk", denied && (try String(contentsOfFile: readonly, encoding: .utf8)) == "readonly")
    let copied = folder.appendingPathComponent("另存.md").path
    let target = try await bridge.backend.perform { try $0.saveTarget(path: copied) }
    _ = try await bridge.call("saveDocument", arguments: [target])
    try await bridge.backend.perform { try $0.releaseSaveTarget(targetJson: target) }
    try check("rust-wk-save-as-after-conflict", try Data(contentsOf: URL(fileURLWithPath: copied)) == bom + Data((local ?? "").utf8))
    try check("rust-wk-save-as-clears-dirty", try await snapshot()["dirty"] as? Bool == false)
    // Leave a clean document for native verifier teardown.
    return passed
    } catch {
        throw NSError(domain: "DocumentVerification", code: 3, userInfo: [NSLocalizedDescriptionKey: "Document verification \(step): \(error.localizedDescription)"])
    }
}
