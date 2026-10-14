import Foundation

/// View geometry only. Coalesce animation frames without queuing stale layouts.
@MainActor
final class EditorViewport {
    private let bridge: EditorBridge
    private var width: CGFloat = 0
    private var revision: UInt64 = 0
    private var delivered: UInt64?
    private var available = false
    private var task: Task<Void, Never>?
    private var lifetime: UInt64 = 0
    init(bridge: EditorBridge) { self.bridge = bridge }
    func resize(_ value: CGFloat) {
        guard value.isFinite, value > 0, value != width else { return }
        width = value; revision += 1; deliver()
    }
    func setAvailable(_ value: Bool) {
        available = value
        if !value { lifetime += 1; delivered = nil; task?.cancel(); task = nil }
        else { deliver() }
    }
    private func deliver() {
        guard available, task == nil, delivered != revision, width > 0 else { return }
        let generation = bridge.generation
        let owner = lifetime
        task = Task { [weak self] in
            guard let self else { return }
            defer { if lifetime == owner { task = nil } }
            while available, !Task.isCancelled, bridge.generation == generation, delivered != revision {
                let requested = revision, requestedWidth = width
                do { _ = try await bridge.call("setViewportWidth", arguments: [requestedWidth, String(requested), generation]) }
                catch {
                    if !Task.isCancelled, bridge.generation == generation { bridge.onError?(userFacingError(error)) }
                    return
                }
                guard !Task.isCancelled, bridge.generation == generation else { return }
                delivered = requested
            }
        }
    }
    func detach() { setAvailable(false) }
}
