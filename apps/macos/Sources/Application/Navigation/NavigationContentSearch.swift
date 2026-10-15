import AppKit

/// One query/result owner for all sidebar views. A tab change subscribes to the
/// same results and never starts another scan of the workspace.
@MainActor
final class NavigationContentSearch {
    private let backend: DocumentBackend
    private(set) var root: String?
    private(set) var query = ""
    private(set) var hits: [WorkspaceHit] = []
    private(set) var notice = ""
    private(set) var active = false
    private var listeners: [UUID: () -> Void] = [:]
    private var service: WorkspaceService?
    private var task: Task<Void, Never>?
    private var sequence: UInt64 = 0
    init(backend: DocumentBackend) { self.backend = backend }
    func observe(_ action: @escaping () -> Void) -> UUID { let id = UUID(); listeners[id] = action; return id }
    func removeObserver(_ id: UUID) { listeners.removeValue(forKey: id) }
    private func publish() { for listener in Array(listeners.values) { listener() } }
    func show(root: String?) {
        active = true
        if self.root != root { self.root = root; search() }
        else { if query.isEmpty { notice = localized(root == nil ? "navigation.chooseWorkspace" : "navigation.enterContentQuery") }; publish() }
    }
    func rebind(root: String?) { guard self.root != root else { return }; self.root = root; if active { search() } }
    func changeQuery(_ query: String) { guard self.query != query else { return }; self.query = query; search() }
    func close() { cancel(); active = false; publish() }
    func cancel() { service?.cancel(queryId: sequence); sequence &+= 1; task?.cancel(); task = nil }
    private func search() {
        cancel(); let expected = sequence, query = query
        guard let root, !query.isEmpty else { hits = []; notice = localized(root == nil ? "navigation.chooseWorkspace" : "navigation.enterContentQuery"); publish(); return }
        hits = []; notice = localized("analysis.parsing"); publish()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                let service = try await backend.perform { try $0.openWorkspace(path: root) }
                guard !Task.isCancelled, expected == sequence else { return }; self.service = service
                let options = WorkspaceSearchOptions(text: query, content: true, caseSensitive: false, regex: false, wholeWord: false, includeHidden: false)
                let result = try await Task.detached { try service.search(queryId: expected, options: options) }.value
                guard !Task.isCancelled, expected == sequence, !result.cancelled else { return }
                hits = result.hits
                notice = result.truncated ? localized("navigation.partial") : hits.isEmpty ? localized("navigation.noResults") : ""
                publish()
            } catch { guard !Task.isCancelled, expected == sequence else { return }; notice = userFacingError(error); publish() }
        }
    }
}
