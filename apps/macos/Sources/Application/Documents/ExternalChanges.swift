import AppKit

private final class DocumentObserver: DocumentChangeListener, @unchecked Sendable {
    private let callback: @Sendable () -> Void
    init(_ callback: @escaping @Sendable () -> Void) { self.callback = callback }
    func changed() { callback() }
}
@MainActor
final class ExternalChanges {
    private let bridge: EditorBridge
    private var watch: DocumentWatch?
    private var binding: (String, String)?
    private var generation = 0
    private var checking = false
    private var invalidated = false
    var onChange: ((String) -> Void)?
    var onError: ((String) -> Void)?
    init(bridge: EditorBridge) { self.bridge = bridge }
    func bind(session: String?, file: String?) {
        guard let session, let file else { detach(); return }
        if binding?.0 == session && binding?.1 == file { return }
        detach(); binding = (session, file)
        let generation = self.generation
        Task { [weak self] in
            guard let self else { return }
            do {
                let listener = DocumentObserver { [weak self] in Task { @MainActor in
                    guard let self, self.generation == generation else { return }; self.check()
                } }
                let watch = try await bridge.backend.perform { try $0.watchDocument(sessionId: session, fileRef: file, listener: listener) }
                guard self.generation == generation else { return }
                self.watch = watch; check()
            } catch { if self.generation == generation { onError?(error.localizedDescription) } }
        }
    }
    func check() {
        guard binding != nil else { return }
        invalidated = true
        guard !checking else { return }
        checking = true
        Task { [weak self] in
            guard let self else { return }
            defer { checking = false; if invalidated { check() } }
            while invalidated, let (session, file) = binding {
                invalidated = false; let generation = self.generation
                do {
                    let state = try await bridge.backend.perform { try $0.externalChange(sessionId: session, fileRef: file) }
                    if self.generation == generation { onChange?(state) }
                } catch { if self.generation == generation { onError?(error.localizedDescription) } }
            }
        }
    }
    func detach() { generation += 1; watch = nil; binding = nil; invalidated = false }
}
