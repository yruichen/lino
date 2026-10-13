import AppKit

struct RecoveryEntry: Decodable, Sendable {
    let key: String
    let label: String?
    let problem: String?
}

// Native ownership is limited to the application's storage location and dialogs.
// The Rust service validates, reads, retires and restores every draft.
@MainActor
final class RecoveryCoordinator {
    private let backend: DocumentBackend
    private let verifying: Bool
    private var configured = false
    private var temporaryDirectory: URL?
    var verificationPath: String? { temporaryDirectory?.path }

    init(backend: DocumentBackend, verifying: Bool) { self.backend = backend; self.verifying = verifying }

    func configure() async throws {
        guard !configured else { return }
        let directory: URL
        if verifying {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("lino-recovery-verify-\(UUID().uuidString)", isDirectory: true)
            temporaryDirectory = directory
        } else {
            // Keep the published storage location across the Lino rename so
            // existing protected drafts remain available without relocation.
            directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("OpenTypora/Recovery", isDirectory: true)
        }
        let path = directory.path
        try await backend.perform { try $0.configureRecovery(path: path) }
        configured = true
    }

    func choose(in window: NSWindow, announceEmpty: Bool) async throws -> String? {
        while true {
            let json = try await backend.perform { try $0.listRecoveries() }
            let entries = try JSONDecoder().decode([RecoveryEntry].self, from: Data(json.utf8))
            guard !entries.isEmpty else {
                if announceEmpty {
                    let alert = NSAlert()
                    alert.messageText = localized("recovery.emptyTitle")
                    alert.informativeText = localized("recovery.emptyDetail")
                    alert.addButton(withTitle: localized("button.ok"))
                    _ = await alert.beginSheetModal(for: window)
                }
                return nil
            }
            switch await DocumentDialogs.recovery(in: window, entries: entries) {
            case .later: return nil
            case .restore(let key): return key
            case .discard(let key): try await backend.perform { try $0.discardRecovery(key: key) }
            }
        }
    }

    func cleanupVerificationFiles() {
        guard let temporaryDirectory else { return }
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}
