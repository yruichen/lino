import Foundation

// Programmatic WKWebView checks only touch synthetic files and the app's isolated
// verification recovery directory. They do not interact with user windows or IME.
@MainActor
func verifyRecoveryFlow(bridge: EditorBridge, onStep: (String) -> Void = { _ in }) async throws -> [String] {
    var passed: [String] = []
    func check(_ name: String, _ condition: Bool) throws {
        if !condition { throw NSError(domain: "RecoveryVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
        passed.append(name)
    }
    func snapshot() async throws -> [String: Any] { try await bridge.call("snapshot") as? [String: Any] ?? [:] }
    func waitFor(_ predicate: ([String: Any]) -> Bool) async throws -> [String: Any] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            let state = try await snapshot()
            if predicate(state) { return state }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "RecoveryVerification", code: 2, userInfo: [NSLocalizedDescriptionKey: "自动保存未在验证时限内完成。"])
    }
    onStep("checkpoint")
    _ = try await bridge.call("setAutosave", arguments: [false])
    let source = try await bridge.call("verifyDocumentEdit") as? String
    _ = try await bridge.call("checkpointDocument")
    let durable = try await snapshot()
    try check("rust-wk-checkpoint-durable", durable["recoveryState"] as? String == "saved" && durable["dirty"] as? Bool == true)
    let before = durable["document"] as? [String: Any]
    onStep("reattach")
    _ = try await bridge.call("prepareReplacement")
    guard let sessionId = before?["session_id"] as? String else {
        throw NSError(domain: "RecoveryVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing document session"])
    }
    let reattached = try await bridge.backend.perform { try $0.reattachDocument(sessionId: sessionId) }
    _ = try await bridge.call("attachDocument", arguments: [reattached])
    let recovered = try await snapshot()
    let after = recovered["document"] as? [String: Any]
    try check("rust-wk-reattach-accepted-source", recovered["text"] as? String == source && recovered["dirty"] as? Bool == true)
    try check("rust-wk-reattach-new-epoch", before?["epoch"] as? String != after?["epoch"] as? String && recovered["canUndo"] as? Bool == false)

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lino-autosave-verify-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("自动保存.md").path
    onStep("manual-save")
    let target = try await bridge.backend.perform { try $0.saveTarget(path: path) }
    _ = try await bridge.call("saveDocument", arguments: [target])
    try await bridge.backend.perform { try $0.releaseSaveTarget(targetJson: target) }
    _ = try await bridge.call("setAutosave", arguments: [true])
    let expected = try await bridge.call("verifyDocumentEdit") as? String ?? ""
    onStep("autosave")
    _ = try await waitFor { $0["dirty"] as? Bool == false && $0["saving"] as? Bool == false }
    let bom = Data([0xef, 0xbb, 0xbf])
    try check("rust-wk-autosave-bound-file", try Data(contentsOf: URL(fileURLWithPath: path)) == bom + Data(expected.utf8))

    let previousErrorHandler = bridge.onError
    bridge.onError = { _ in } // The expected conflict is asserted through state and bytes below.
    defer { bridge.onError = previousErrorHandler }
    try Data("external autosave conflict\n".utf8).write(to: URL(fileURLWithPath: path))
    let local = try await bridge.call("verifyDocumentEdit") as? String
    onStep("conflict")
    let conflicted = try await waitFor { $0["autosaveError"] as? String != nil }
    try check("rust-wk-autosave-conflict-keeps-local", conflicted["dirty"] as? Bool == true && conflicted["text"] as? String == local)
    try check("rust-wk-autosave-conflict-keeps-disk", try String(contentsOfFile: path, encoding: .utf8) == "external autosave conflict\n")
    _ = try await bridge.call("setAutosave", arguments: [false])
    _ = try await bridge.call("checkpointDocument")
    _ = try await bridge.call("prepareReplacement")
    let intent = try await bridge.call("replacementIntent", arguments: [true]) as? String
    let clean = try await bridge.backend.perform { try $0.newDocument(replaceJson: intent) }
    _ = try await bridge.call("attachDocument", arguments: [clean])
    let listing = try await bridge.backend.perform { try $0.listRecoveries() }
    let remaining = try JSONDecoder().decode([RecoveryEntry].self, from: Data(listing.utf8))
    try check("rust-wk-discard-retires-recovery", remaining.isEmpty)
    return passed
}
