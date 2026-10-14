import AppKit

@MainActor
final class DocumentActions: DocumentCloseParticipant {
    private let bridge: EditorBridge
    private let recovery: RecoveryCoordinator
    private let verifying: Bool
    private weak var window: NSWindow?
    private var initialized = false
    private let initialPath: String?
    var openingPath: String? { initialized ? nil : initialPath }
    private let offerRecovery: Bool
    private(set) var sessionId: String?
    private var closeIntent: String?
    private var abandonOnClose = false
    private(set) var ready = false { didSet { onAvailabilityChanged?() } }
    private(set) var busy = false { didSet { onAvailabilityChanged?() } }
    private(set) var closed = false
    private(set) var autosave: Bool
    var onAvailabilityChanged: (() -> Void)?
    var onOperationStarted: (() -> Void)?
    var onReattached: (() -> Void)?
    var hasFile = false
    var label: String?
    var fileRef: String?
    var readOnly = false

    init(bridge: EditorBridge, window: NSWindow, verifying: Bool, initialPath: String? = nil, offerRecovery: Bool = true) {
        self.initialPath = initialPath; self.offerRecovery = offerRecovery
        self.bridge = bridge; self.window = window; self.verifying = verifying
        recovery = RecoveryCoordinator(backend: bridge.backend, verifying: verifying)
        autosave = false
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
            guard let sessionId else { throw unavailable(localized("error.replacementContext")) }
            json = try await bridge.backend.perform { try $0.reattachDocument(sessionId: sessionId) }
        } else {
            let selected = offerRecovery && initialPath == nil && !verifying && window != nil ? try await recovery.choose(in: window!, announceEmpty: false) : nil
            if let initialPath { json = try await bridge.backend.perform { try $0.openFile(path: initialPath, replaceJson: nil) } }
            else if let selected { json = try await bridge.backend.perform { try $0.restoreRecovery(key: selected, replaceJson: nil) } }
            else { json = try await bridge.backend.perform { try $0.newDocument(replaceJson: nil) } }
            // A failed view attachment must reconnect this session, not create another.
            rememberSession(json)
        }
        try requireGeneration(generation)
        _ = try await bridge.call("attachDocument", arguments: [json])
        let preferences = try await bridge.backend.perform { try $0.preferences() }
        try requireGeneration(generation)
        try await applyPreferences(preferences)
        _ = try await bridge.call("setLocale", arguments: [LanguagePreferences.shared.locale])
        _ = try await bridge.call("preparePresentation")
        try requireGeneration(generation)
        ready = true
        if reattaching { onReattached?() }
    }

    func viewTerminated() { ready = false }
    var verificationRecoveryPath: String? { recovery.verificationPath }
    func cleanupVerificationFiles() { recovery.cleanupVerificationFiles() }
    private func show(_ error: Error) { bridge.onError?(userFacingError(error)) }
    private func unavailable(_ message: String) -> NSError {
        NSError(domain: "Lino", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func requireGeneration(_ generation: Int) throws {
        guard bridge.generation == generation else { throw unavailable(localized("error.viewChanged")) }
    }

    func toggleAutosave() async {
        guard ready && !busy && !closed else { return }
        let enabled = !autosave
        do {
            try await applyAutosave(enabled)
        } catch { show(error) }
    }
    func applyAutosave(_ enabled: Bool) async throws {
        guard ready && !closed else { throw unavailable(localized("error.busy")) }
        _ = try await bridge.call("setAutosave", arguments: [enabled])
        autosave = enabled
    }
    func applyPreferences(_ json: String) async throws {
        let value = try PreferencesCoordinator.decode(json)
        _ = try await bridge.call("applyPreferences", arguments: [json])
        autosave = value.values.auto_save
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
            let resourceNote = (try await bridge.call("hasLocalImages")) as? Bool == true
            guard let window, let path = await DocumentDialogs.save(in: window, label: label, resourceNote: resourceNote)?.path else { return false }
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
    @discardableResult
    func save(asNew: Bool = false) async -> Bool {
        guard ready && !busy && !closed else { return false }
        busy = true; defer { busy = false }
        onOperationStarted?()
        do { return try await saveCurrent(asNew: asNew) } catch { show(error); return false }
    }

    private func replacementIntent(closing: Bool = false) async throws -> String? {
        let value = try await bridge.call("prepareReplacement")
        guard let context = value as? [String: Any], let original = context["intentJson"] as? String else {
            throw NSError(domain: "Lino", code: 3, userInfo: [NSLocalizedDescriptionKey: localized("error.replacementContext")])
        }
        guard context["dirty"] as? Bool == true else { return original }
        guard let window else { return nil }
        switch await DocumentDialogs.unsaved(in: window, label: label ?? localized("document.untitled"), closing: closing) {
        case .cancel: return nil
        case .discard: return try await bridge.call("replacementIntent", arguments: [true]) as? String
        case .save:
            guard try await saveCurrent(asNew: false) else { return nil }
            return try await bridge.call("replacementIntent", arguments: [false]) as? String
        }
    }

    /// Reuse only a pristine, unbound page. Eligibility is checked while input
    /// and persistence are frozen by the existing replacement transaction.
    func openIfEmpty(path: String) async throws -> Bool {
        guard ready && !busy && !closed && !hasFile else { return false }
        busy = true
        do {
            let generation = bridge.generation
            let value = try await bridge.call("prepareReplacement")
            try requireGeneration(generation)
            guard let context = value as? [String: Any], context["dirty"] as? Bool == false,
                  context["hasFile"] as? Bool == false, context["replaceableEmpty"] as? Bool == true,
                  let intent = context["intentJson"] as? String else {
                _ = try? await bridge.call("cancelReplacement"); busy = false; return false
            }
            let json = try await bridge.backend.perform { try $0.openFile(path: path, replaceJson: intent) }
            try await attachReplacement(json, generation: generation)
            _ = try? await bridge.call("cancelReplacement"); busy = false
            return true
        } catch {
            _ = try? await bridge.call("cancelReplacement"); busy = false
            throw error
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
    func reloadFile() async {
        guard ready && !busy && !closed, let file = fileRef else { return }
        busy = true; defer { busy = false }
        onOperationStarted?()
        do {
            if let intent = try await replacementIntent() {
                let generation = bridge.generation
                let json = try await bridge.backend.perform { try $0.reloadDocument(intentJson: intent, fileRef: file) }
                try await attachReplacement(json, generation: generation)
            }
        } catch { show(error) }
        _ = try? await bridge.call("cancelReplacement")
    }
    func toggleReadOnly() async {
        guard ready && !busy && !closed else { return }
        busy = true; defer { busy = false }
        var committed = false
        do {
            guard let intent = try await bridge.call("prepareDocumentReadOnly") as? [String: Any],
                  let id = intent["session_id"] as? String, let epoch = intent["epoch"] as? String, let revision = intent["revision"] as? String else { throw unavailable(localized("error.replacementContext")) }
            let value = !readOnly
            let updated = try await bridge.backend.perform { try $0.setDocumentReadOnly(sessionId: id, epoch: epoch, revision: revision, value: value) }
            committed = true
            _ = try await bridge.call("applyDocumentReadOnly", arguments: [updated])
        } catch { if committed { ready = false }; show(error) }
        _ = try? await bridge.call("cancelReplacement")
    }

    private func rememberSession(_ json: String) {
        let opened = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        sessionId = (opened?["status"] as? [String: Any])?["session_id"] as? String
        bridge.sessionId = sessionId
        initialized = sessionId != nil
    }
    private func attachReplacement(_ json: String, generation: Int) async throws {
        rememberSession(json)
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

    func prepareClose() async -> Bool {
        if closed { return true }
        guard !busy else { return false }
        busy = true
        if !ready {
            guard let window, await DocumentDialogs.closeUnavailable(in: window) else { busy = false; return false }
            abandonOnClose = true
            return true
        }
        do {
            guard let intent = try await replacementIntent(closing: true) else { await cancelClose(); return false }
            closeIntent = intent
            return true
        } catch { show(error); await cancelClose(); return false }
    }
    func cancelClose() async {
        closeIntent = nil; abandonOnClose = false
        if ready { _ = try? await bridge.call("cancelReplacement") }
        busy = false
    }
    func commitClose() async -> Bool {
        if closed { return true }
        do {
            if abandonOnClose {
                if let sessionId { try await bridge.backend.perform { try $0.abandonDocument(sessionId: sessionId) } }
            } else {
                guard let closeIntent else { await cancelClose(); return false }
                _ = try await bridge.call("closeDocument", arguments: [closeIntent])
            }
            closed = true; busy = false; return true
        } catch { show(error); await cancelClose(); return false }
    }
    func close() async -> Bool {
        guard await prepareClose() else { return false }
        return await commitClose()
    }
}
