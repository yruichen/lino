import AppKit

struct NavigationPreferences: Codable, Equatable, Sendable {
    var locations: [String] = []
    var favorites: [String] = []
    var sections = ["favorites", "locations", "open_files", "recents"]
    var show_favorites = true
    var show_locations = true
    var show_open_files = true
    var show_recents = false
    var follow_active = false
    var show_root = false
    var show_extensions = true
    var compact = false
    var sort = "name"
}
struct NavigationSnapshot: Codable, Sendable {
    let schema_version: UInt32
    let revision: UInt64
    var values: NavigationPreferences
    let recent: [String]
    let storage_warning: Bool
}
final class NavigationObserver: WorkspaceListener, @unchecked Sendable {
    let action: @Sendable () -> Void
    init(_ action: @escaping @Sendable () -> Void) { self.action = action }
    func changed() { action() }
}

/// Read-only native projection of the shared navigation service. UI operations are
/// serialized here; Rust owns revisions, validation, storage and search indexes.
@MainActor
final class NavigationCoordinator {
    let sidebar = SidebarPresentation()
    lazy var contentSearch = NavigationContentSearch(backend: backend)
    let backend: DocumentBackend
    private(set) var snapshot: NavigationSnapshot?
    private(set) var services: [String: WorkspaceService] = [:]
    private var watchers: [String: NavigationObserver] = [:]
    private var listeners: [UUID: (String?) -> Void] = [:]
    private var tail: Task<Void, Never>?
    private var temporaryDirectory: URL?
    private var directoryUpdates: [String: Task<Void, Never>] = [:]
    private(set) var openFiles: [String] = []
    var onError: ((String) -> Void)?
    var values: NavigationPreferences { snapshot?.values ?? NavigationPreferences() }
    var recent: [String] { snapshot?.recent ?? [] }
    init(backend: DocumentBackend) { self.backend = backend }
    func observe(_ action: @escaping (String?) -> Void) -> UUID { let id = UUID(); listeners[id] = action; return id }
    func removeObserver(_ id: UUID) { listeners.removeValue(forKey: id) }
    private func publish(_ root: String? = nil) { for listener in Array(listeners.values) { listener(root) } }
    func configure(verifying: Bool) async throws {
        sidebar.configure(verifying: verifying)
        let directory: URL
        if verifying {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("lino-navigation-\(UUID().uuidString)")
            temporaryDirectory = directory
        } else {
            directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Lino", isDirectory: true)
        }
        let path = directory.appendingPathComponent("navigation.json").path
        let legacy = verifying ? [] : UserDefaults.standard.stringArray(forKey: "pinnedWorkspaceRoots") ?? []
        snapshot = try decode(await backend.perform { try $0.configureNavigation(path: path, legacyLocations: legacy) })
        await reconcileServices()
        if !verifying { UserDefaults.standard.removeObject(forKey: "pinnedWorkspaceRoots") }
        publish()
    }
    private func decode(_ json: String) throws -> NavigationSnapshot {
        try JSONDecoder().decode(NavigationSnapshot.self, from: Data(json.utf8))
    }
    func change(_ edit: @escaping @MainActor (inout NavigationPreferences) -> Void) async {
        await enqueue { [self] in
            let current = try decode(await backend.perform { try $0.navigation() })
            var values = current.values; edit(&values)
            let json = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
            snapshot = try decode(await backend.perform { try $0.updateNavigation(revision: current.revision, valuesJson: json) })
            await reconcileServices(); publish()
            if snapshot?.storage_warning == true { onError?(localized("settings.notDurable")) }
        }
    }
    private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) async {
        let previous = tail
        let task = Task { [weak self] in
            await previous?.value
            do { try await operation() }
            catch { self?.onError?(userFacingError(error)) }
        }
        tail = task; await task.value
    }
    @discardableResult
    func addLocation(_ path: String) async -> String? {
        do {
            let service = try await backend.perform { try $0.openWorkspace(path: path) }
            let canonical = service.root()
            await change { if !$0.locations.contains(canonical) { $0.locations.append(canonical) } }
            return values.locations.contains(canonical) ? canonical : nil
        } catch { onError?(userFacingError(error)); return nil }
    }
    @discardableResult
    func noteFile(_ path: String) async -> String? {
        var canonical: String?
        await enqueue { [self] in
            let next = try decode(await backend.perform { try $0.noteNavigationFile(path: path) })
            canonical = next.recent.first
            let changed = next.revision != snapshot?.revision
            snapshot = next; if changed { publish() }
        }
        return canonical
    }
    func updateOpenFiles(_ paths: [String]) { if paths != openFiles { openFiles = paths; publish() } }
    private func reconcileServices() async {
        for root in Array(services.keys) where !values.locations.contains(root) && !values.favorites.contains(root) {
            let removed = services.removeValue(forKey: root); watchers.removeValue(forKey: root)
            directoryUpdates.removeValue(forKey: root)?.cancel()
            if let removed { Task.detached { removed.unwatch() } }
        }
        for root in Array(Set(values.locations + values.favorites)).sorted() where services[root] == nil {
            do {
                let service = try await backend.perform { try $0.openWorkspace(path: root) }
                services[root] = service
                let watcher = NavigationObserver { [weak self] in Task { @MainActor in self?.directoryChanged(root) } }
                watchers[root] = watcher
                do { try await Task.detached { try service.watch(listener: watcher) }.value }
                catch { onError?(userFacingError(error)) }
            } catch { if values.locations.contains(root) { onError?(userFacingError(error)) } }
        }
    }
    private func directoryChanged(_ root: String) {
        guard services[root] != nil else { return }
        directoryUpdates[root]?.cancel()
        directoryUpdates[root] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled, let service = services[root] else { return }
            // Acknowledge the coalesced watcher before publishing invalidation.
            await Task.detached { service.acknowledgeChanges() }.value
            try? await backend.perform { $0.invalidateNavigation() }
            guard !Task.isCancelled else { return }
            publish(root); directoryUpdates.removeValue(forKey: root)
        }
    }
    func refresh() async { await reconcileServices(); try? await backend.perform { $0.invalidateNavigation() }; publish("") }
    func detach() {
        contentSearch.cancel()
        for task in directoryUpdates.values { task.cancel() }
        for service in services.values { Task.detached { service.unwatch() } }
        services.removeAll(); watchers.removeAll(); listeners.removeAll()
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }
}
