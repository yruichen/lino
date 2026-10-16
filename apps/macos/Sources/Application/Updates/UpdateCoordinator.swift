import AppKit

struct UpdateRelease: Codable, Sendable {
    let version: String
    let url: String
    let prerelease: Bool
}
struct UpdateCheck: Codable, Sendable {
    let newer: Bool
    let release: UpdateRelease?
}

@MainActor
final class UpdateCoordinator {
    enum State { case idle, checking, checked(UpdateCheck), failed(String) }
    let currentVersion: String
    private let backend: DocumentBackend
    private let defaults: UserDefaults?
    private let fetch: @Sendable (String) async throws -> String
    private(set) var state = State.idle
    private(set) var lastChecked: Date?
    private(set) var lastResult: UpdateCheck?
    private var automatic = false
    private var includePrereleases = true
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var listeners: [UUID: () -> Void] = [:]
    init(backend: DocumentBackend, defaults: UserDefaults? = .standard, currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0", fetch: @escaping @Sendable (String) async throws -> String = { try await ReleaseFeedClient().fetch(version: $0) }) {
        self.backend = backend; self.defaults = defaults; self.currentVersion = currentVersion; self.fetch = fetch
    }
    func observe(_ action: @escaping () -> Void) -> UUID { let id = UUID(); listeners[id] = action; return id }
    func removeObserver(_ id: UUID) { listeners.removeValue(forKey: id) }
    private func publish() { for listener in Array(listeners.values) { listener() } }
    func configure(_ values: EditorPreferences) {
        if includePrereleases != values.include_prerelease_updates {
            cancel(); state = .idle; lastChecked = nil; lastResult = nil
        }
        automatic = values.automatic_update_checks; includePrereleases = values.include_prerelease_updates
        if lastChecked == nil { lastChecked = defaults?.object(forKey: "updates.lastSuccess." + (includePrereleases ? "beta" : "stable")) as? Date }
        publish()
    }
    func checkAutomatically() {
        guard automatic else { return }
        let key = "updates.lastAttempt." + (includePrereleases ? "beta" : "stable")
        if let last = defaults?.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 24 * 60 * 60 { return }
        check()
    }
    func check() {
        guard task == nil else { return }
        generation &+= 1; let expected = generation, include = includePrereleases, fetch = fetch, version = currentVersion
        defaults?.set(Date(), forKey: "updates.lastAttempt." + (include ? "beta" : "stable"))
        state = .checking; publish()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let json = try await fetch(version)
                try Task.checkCancellation()
                let result = try await backend.perform { try $0.evaluateReleases(releasesJson: json, currentVersion: version, includePrereleases: include) }
                guard !Task.isCancelled, expected == generation else { return }
                let check = try JSONDecoder().decode(UpdateCheck.self, from: Data(result.utf8))
                lastChecked = Date(); lastResult = check; state = .checked(check)
                defaults?.set(lastChecked, forKey: "updates.lastSuccess." + (include ? "beta" : "stable"))
            } catch {
                guard !Task.isCancelled, expected == generation else { return }
                switch error {
                case ReleaseFetchError.rateLimited: state = .failed(localized("updates.rateLimited"))
                case ReleaseFetchError.http(let code): state = .failed(localized("updates.httpError", code))
                case ReleaseFetchError.invalidResponse, ReleaseFetchError.tooLarge: state = .failed(localized("updates.invalidResponse"))
                case let error as BackendFailure where error.code == "invalid_message": state = .failed(localized("updates.invalidResponse"))
                default: state = .failed(localized("updates.networkError"))
                }
            }
            guard expected == generation else { return }
            task = nil; publish()
        }
    }
    func openRelease() {
        if let release = lastResult?.release, let url = URL(string: release.url), url.scheme == "https", url.host == "github.com", url.path.hasPrefix("/yruichen/lino/releases/tag/") {
            NSWorkspace.shared.open(url)
        } else { NSWorkspace.shared.open(URL(string: "https://github.com/yruichen/lino/releases")!) }
    }
    func cancel() { generation &+= 1; task?.cancel(); task = nil }
}
