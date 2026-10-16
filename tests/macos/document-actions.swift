import AppKit

// The UI and WebKit transport are replaced; DocumentActions and the close group
// run unchanged. Real filesystem version checks are covered by runtime/documents.
struct FixtureFailure: Error {}
final class DocumentService: @unchecked Sendable {
    var disk = "external"
    var savedVersion = "original"
    var copy: String?
    var released: [String] = []
    func externalChange(sessionId: String, fileRef: String) throws -> String { disk == savedVersion ? "unchanged" : "changed" }
    func documentPath(sessionId: String) throws -> String? { "/fixture/document.md" }
    func saveTarget(path: String) throws -> String {
        let original = path == "/fixture/document.md"
        return String(data: try JSONSerialization.data(withJSONObject: ["file_ref": original ? "10" : "20", "expected_version": original ? disk as Any : NSNull(), "label": "document.md", "reservation_id": "1"]), encoding: .utf8)!
    }
    func releaseSaveTarget(targetJson: String) throws { released.append(targetJson) }
    func newDocument(replaceJson: String?) throws -> String { "{\"status\":{\"session_id\":\"1\"}}" }
    func openFile(path: String, replaceJson: String?) throws -> String { try newDocument(replaceJson: replaceJson) }
    func reattachDocument(sessionId: String) throws -> String { try newDocument(replaceJson: nil) }
    func restoreRecovery(key: String, replaceJson: String?) throws -> String { try newDocument(replaceJson: replaceJson) }
    func reloadDocument(intentJson: String, fileRef: String) throws -> String { try newDocument(replaceJson: nil) }
    func preferences() throws -> String { "{}" }
    func setDocumentReadOnly(sessionId: String, epoch: String, revision: String, value: Bool) throws -> String { "{}" }
    func abandonDocument(sessionId: String) throws {}
}
final class DocumentBackend: Sendable {
    let service = DocumentService()
    @MainActor func perform<T: Sendable>(_ action: @escaping @Sendable (DocumentService) throws -> T) async throws -> T { try action(service) }
}
@MainActor final class EditorBridge {
    let backend = DocumentBackend()
    var generation = 0
    var sessionId: String?
    var onError: ((String) -> Void)?
    let local = "local edits"
    var dirty = true
    var frozen = false
    var didClose = false
    var errors = 0
    func call(_ name: String, arguments: [Any] = []) async throws -> Any {
        switch name {
        case "prepareReplacement": frozen = true; return ["dirty": dirty, "intentJson": "intent"] as [String: Any]
        case "cancelReplacement": frozen = false
        case "replacementIntent": return "intent"
        case "closeDocument": guard !dirty else { throw FixtureFailure() }; didClose = true
        case "hasLocalImages": return false
        case "saveDocument":
            let target = (arguments.first as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            if target?["file_ref"] as? String == "20" { backend.service.copy = local }
            else {
                guard backend.service.disk == (target?["expected_version"] as? String ?? backend.service.savedVersion) else { throw FixtureFailure() }
                backend.service.disk = local
                backend.service.savedVersion = local
            }
            dirty = false
        default: break
        }
        return NSNull()
    }
}
@MainActor final class RecoveryCoordinator {
    init(backend: DocumentBackend, verifying: Bool) {}
    var verificationPath: String? { nil }
    func configure() async throws {}
    func choose(in window: NSWindow, announceEmpty: Bool) async throws -> String? { nil }
    func cleanupVerificationFiles() {}
}
@MainActor enum PreferencesCoordinator {
    struct Values { var auto_save = false }
    struct Value { var values = Values() }
    static func decode(_ json: String) throws -> Value { Value() }
}
@MainActor final class LanguagePreferences {
    static let shared = LanguagePreferences()
    let locale = "en"
}
@MainActor func localized(_ key: String) -> String { key }
@MainActor func userFacingError(_ error: Error) -> String { "fixture failure" }
@MainActor enum DocumentDialogs {
    enum Decision { case save, discard, cancel }
    enum ConflictDecision { case overwrite, saveCopy, cancel }
    static var conflictDecision = ConflictDecision.overwrite
    static var duringConflict: (() -> Void)?
    static var conflicts = 0
    static var saveURL: URL? = URL(fileURLWithPath: "/fixture/copy.md")
    static func conflict(in window: NSWindow, label: String) async -> ConflictDecision {
        conflicts += 1; duringConflict?(); return conflictDecision
    }
    static func save(in window: NSWindow, label: String?, resourceNote: Bool) async -> URL? { saveURL }
    static func unsaved(in window: NSWindow, label: String, closing: Bool) async -> Decision { .save }
    static func open(in window: NSWindow) async -> URL? { nil }
    static func closeUnavailable(in window: NSWindow) async -> Bool { false }
}
@main struct Checks {
    @MainActor static func fixture() async throws -> (DocumentActions, EditorBridge, NSWindow) {
        let bridge = EditorBridge(), window = NSWindow()
        let actions = DocumentActions(bridge: bridge, window: window, verifying: true, offerRecovery: false)
        try await actions.initialize()
        actions.hasFile = true; actions.fileRef = "10"; actions.label = "document.md"
        DocumentDialogs.conflictDecision = .overwrite; DocumentDialogs.duringConflict = nil; DocumentDialogs.conflicts = 0
        DocumentDialogs.saveURL = URL(fileURLWithPath: "/fixture/copy.md")
        bridge.onError = { _ in bridge.errors += 1 }
        return (actions, bridge, window)
    }
    @MainActor static func main() async throws {
        let (manual, manualBridge, manualWindow) = try await fixture()
        let saved = await manual.save()
        precondition(saved && manualBridge.backend.service.disk == "local edits", "Manual Save must offer explicit conflict resolution and save local edits")
        precondition(DocumentDialogs.conflicts == 1 && manualBridge.backend.service.released.count == 1 && !manual.busy)
        withExtendedLifetime(manualWindow) {}

        let (unchanged, unchangedBridge, unchangedWindow) = try await fixture()
        unchangedBridge.backend.service.disk = "original"
        let unchangedSaved = await unchanged.save()
        precondition(unchangedSaved && unchangedBridge.backend.service.disk == "local edits" && DocumentDialogs.conflicts == 0)
        precondition(unchangedBridge.backend.service.released.isEmpty)
        withExtendedLifetime(unchangedWindow) {}

        let (closing, closeBridge, closeWindow) = try await fixture()
        let closed = await closeDocumentGroup([closing])
        precondition(closed && closing.closed && closeBridge.didClose && closeBridge.backend.service.disk == "local edits", "Save and Close must resolve the same external conflict")
        withExtendedLifetime(closeWindow) {}

        let (cancelled, cancelBridge, cancelWindow) = try await fixture()
        DocumentDialogs.conflictDecision = .cancel
        let cancelledClose = await closeDocumentGroup([cancelled])
        precondition(!cancelledClose && !cancelled.closed && !cancelled.busy && !cancelBridge.frozen && cancelBridge.dirty)
        precondition(cancelBridge.backend.service.disk == "external" && cancelBridge.backend.service.released.count == 1)
        DocumentDialogs.conflictDecision = .overwrite
        let retriedClose = await closeDocumentGroup([cancelled])
        precondition(retriedClose && cancelled.closed)
        withExtendedLifetime(cancelWindow) {}

        let (raced, raceBridge, raceWindow) = try await fixture()
        DocumentDialogs.duringConflict = { raceBridge.backend.service.disk = "new external" }
        let raceClose = await closeDocumentGroup([raced])
        precondition(!raceClose && !raced.busy && !raceBridge.frozen && raceBridge.dirty)
        precondition(raceBridge.backend.service.disk == "new external" && raceBridge.backend.service.released.count == 1)
        DocumentDialogs.duringConflict = nil
        let raceRetry = await closeDocumentGroup([raced])
        precondition(raceRetry && raced.closed)
        withExtendedLifetime(raceWindow) {}

        let (copy, copyBridge, copyWindow) = try await fixture()
        DocumentDialogs.conflictDecision = .saveCopy
        let copied = await copy.save()
        precondition(copied && copyBridge.backend.service.copy == "local edits" && copyBridge.backend.service.disk == "external")
        precondition(copyBridge.backend.service.released.count == 2)
        withExtendedLifetime(copyWindow) {}

        let (copyCancelled, copyCancelBridge, copyCancelWindow) = try await fixture()
        DocumentDialogs.conflictDecision = .saveCopy; DocumentDialogs.saveURL = nil
        let copyWasCancelled = await closeDocumentGroup([copyCancelled])
        precondition(!copyWasCancelled && !copyCancelled.busy && !copyCancelBridge.frozen && copyCancelBridge.dirty)
        precondition(copyCancelBridge.backend.service.disk == "external" && copyCancelBridge.backend.service.released.count == 1)
        withExtendedLifetime(copyCancelWindow) {}

        let (late, lateBridge, lateWindow) = try await fixture()
        DocumentDialogs.duringConflict = { lateBridge.generation += 1 }
        let lateSaved = await late.save()
        precondition(!lateSaved && lateBridge.dirty && lateBridge.backend.service.disk == "external")
        precondition(lateBridge.backend.service.released.count == 1 && !late.busy)
        withExtendedLifetime(lateWindow) {}
        print("Document actions: manual conflict save, save and close, cancellation, disk race, retry and Save As passed.")
    }
}
