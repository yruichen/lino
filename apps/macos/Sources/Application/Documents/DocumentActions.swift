import AppKit

@MainActor
final class DocumentActions {
    private let bridge: EditorBridge
    private let recovery: RecoveryCoordinator
    private let verifying: Bool
    private weak var window: NSWindow?
    private var initialized = false
    private(set) var ready = false { didSet { onAvailabilityChanged?() } }
    private(set) var busy = false { didSet { onAvailabilityChanged?() } }
    private(set) var closed = false
    private(set) var autosave: Bool
    var onAvailabilityChanged: (() -> Void)?
    var onOperationStarted: (() -> Void)?
    var onReattached: (() -> Void)?
    var hasFile = false
    var label: String?

    init(bridge: EditorBridge, window: NSWindow, verifying: Bool) {
        self.bridge = bridge; self.window = window; self.verifying = verifying
        recovery = RecoveryCoordinator(backend: bridge.backend, verifying: verifying)
        autosave = verifying ? false : UserDefaults.standard.bool(forKey: "automaticallySaveDocuments")
    }

    func initialize() async throws {
        guard !ready && !closed else { return }
        guard !busy else { throw unavailable(localized("error.busy")) }
        busy = true; defer { busy = false }
        let generation = bridge.generation
        onOperationStarted?()
        try await recovery.configure()
        try requireGeneration(generation)
        let reattaching = initialized
        let json: String
        if reattaching {
            json = try await bridge.backend.perform { try $0.reattachDocument() }
        } else {
            let selected = !verifying && window != nil ? try await recovery.choose(in: window!, announceEmpty: false) : nil
            if let selected { json = try await bridge.backend.perform { try $0.restoreRecovery(key: selected, replaceJson: nil) } }
            else { json = try await bridge.backend.perform { try $0.newDocument(replaceJson: nil) } }
            // A failed view attachment must reconnect this session, not create another.
            initialized = true
        }
        try requireGeneration(generation)
        _ = try await bridge.call("attachDocument", arguments: [json])
        _ = try await bridge.call("setAutosave", arguments: [autosave])
        _ = try await bridge.call("setLocale", arguments: [LanguagePreferences.shared.locale])
        ready = true
        if reattaching { onReattached?() }
    }

    func viewTerminated() { ready = false }
    var verificationRecoveryPath: String? { recovery.verificationPath }
    func cleanupVerificationFiles() { recovery.cleanupVerificationFiles() }
    private func show(_ error: Error) { bridge.onError?(error.localizedDescription) }
    private func unavailable(_ message: String) -> NSError {
        NSError(domain: "OpenTypora", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func requireGeneration(_ generation: Int) throws {
        guard bridge.generation == generation else { throw unavailable(localized("error.viewChanged")) }
    }

    func toggleAutosave() async {
        guard ready && !busy && !closed else { return }
        let enabled = !autosave
        do {
            _ = try await bridge.call("setAutosave", arguments: [enabled])
            autosave = enabled
            if !verifying { UserDefaults.standard.set(enabled, forKey: "automaticallySaveDocuments") }
        } catch { show(error) }
    }

    func retryPersistence() async {
        guard ready && !busy && !closed else { return }
        onOperationStarted?()
        do { _ = try await bridge.call("retryPersistence") } catch { show(error) }
    }

    private func saveCurrent(asNew: Bool) async throws -> Bool {
        let generation = bridge.generation
        var target: String?
        if asNew || !hasFile {
            guard let window, let path = await DocumentDialogs.save(in: window, label: label)?.path else { return false }
            target = try await bridge.backend.perform { try $0.saveTarget(path: path) }
        }
        do {
            try requireGeneration(generation)
            _ = try await bridge.call("saveDocument", arguments: [target as Any? ?? NSNull()])
        }
        catch {
            if let target { try? await bridge.backend.perform { try $0.releaseSaveTarget(targetJson: target) } }
            throw error
        }
        if let target { try? await bridge.backend.perform { try $0.releaseSaveTarget(targetJson: target) } }
        return true
    }
    func save(asNew: Bool = false) async {
        guard ready && !busy && !closed else { return }
        busy = true; defer { busy = false }
        onOperationStarted?()
        do { _ = try await saveCurrent(asNew: asNew) } catch { show(error) }
    }

    private func replacementIntent() async throws -> String? {
        let value = try await bridge.call("prepareReplacement")
        guard let context = value as? [String: Any], let original = context["intentJson"] as? String else {
            throw NSError(domain: "OpenTypora", code: 3, userInfo: [NSLocalizedDescriptionKey: localized("error.replacementContext")])
        }
        guard context["dirty"] as? Bool == true else { return original }
        guard let window else { return nil }
        switch await DocumentDialogs.unsaved(in: window, label: label ?? localized("document.untitled")) {
        case .cancel: return nil
        case .discard: return try await bridge.call("replacementIntent", arguments: [true]) as? String
        case .save:
            guard try await saveCurrent(asNew: false) else { return nil }
            return try await bridge.call("replacementIntent", arguments: [false]) as? String
        }
    }

    func replace(open: Bool) async {
        guard ready && !busy && !closed else { return }
        busy = true; defer { busy = false }
        onOperationStarted?()
        var path: String?
        if open {
            guard let window, let selected = await DocumentDialogs.open(in: window) else { return }
            path = selected.path
        }
        do {
            if let intent = try await replacementIntent() {
                let generation = bridge.generation
                let json: String
                if let path { json = try await bridge.backend.perform { try $0.openFile(path: path, replaceJson: intent) } }
                else { json = try await bridge.backend.perform { try $0.newDocument(replaceJson: intent) } }
                try await attachReplacement(json, generation: generation)
            }
        } catch { show(error) }
        _ = try? await bridge.call("cancelReplacement")
    }

    func restoreDraft() async {
        guard ready && !busy && !closed, let window else { return }
        busy = true; defer { busy = false }
        onOperationStarted?()
        do {
            guard let selected = try await recovery.choose(in: window, announceEmpty: true),
                  let intent = try await replacementIntent() else { _ = try? await bridge.call("cancelReplacement"); return }
            let generation = bridge.generation
            let json = try await bridge.backend.perform { try $0.restoreRecovery(key: selected, replaceJson: intent) }
            try await attachReplacement(json, generation: generation)
        } catch { show(error) }
        _ = try? await bridge.call("cancelReplacement")
    }

    private func attachReplacement(_ json: String, generation: Int) async throws {
        do {
            try requireGeneration(generation)
            _ = try await bridge.call("attachDocument", arguments: [json])
        }
        catch {
            // Rust has already replaced the session. Prevent stale view operations;
            // explicit reconnect acquires its snapshot through a new epoch.
            ready = false
            throw error
        }
    }

    func close() async -> Bool {
        if closed { return true }
        guard !busy else { return false }
        if !ready {
            guard let window else { return false }
            busy = true; defer { busy = false }
            guard await DocumentDialogs.closeUnavailable(in: window) else { return false }
            closed = true
            return true
        }
        busy = true; defer { busy = false }
        do {
            guard let intent = try await replacementIntent() else {
                _ = try? await bridge.call("cancelReplacement"); return false
            }
            _ = try await bridge.call("closeDocument", arguments: [intent]); closed = true; return true
        } catch {
            show(error); _ = try? await bridge.call("cancelReplacement"); return false
        }
    }
}
