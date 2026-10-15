import AppKit

/// Shared navigation presentation; document content and outline entries remain
/// owned by their document. Views subscribe instead of keeping per-file settings.
@MainActor
final class SidebarPresentation {
    struct Values: Codable, Equatable {
        var visible = false
        var width: Double = 268
        var outline = false
        var workspace: String?
        var expanded: Set<String> = []
        var collapsedSections: Set<String> = []
        var filesX: Double = 0, filesY: Double = 0
        var outlineX: Double = 0, outlineY: Double = 0
    }
    private(set) var values = Values()
    private var listeners: [UUID: (Values) -> Void] = [:]
    private var persistent = false
    private let key = "navigationSidebar"
    func configure(verifying: Bool) {
        persistent = !verifying
        if persistent, let data = UserDefaults.standard.data(forKey: key), let stored = try? JSONDecoder().decode(Values.self, from: data) {
            values = stored
            values.width = min(360, max(230, values.width))
        }
    }
    func save() { if persistent, let data = try? JSONEncoder().encode(values) { UserDefaults.standard.set(data, forKey: key) } }
    func observe(_ action: @escaping (Values) -> Void) -> UUID { let id = UUID(); listeners[id] = action; return id }
    func removeObserver(_ id: UUID) { listeners.removeValue(forKey: id) }
    func change(persist: Bool = true, _ edit: (inout Values) -> Void) {
        var next = values; edit(&next)
        guard next != values else { return }
        values = next
        if persist { save() }
        for listener in Array(listeners.values) { listener(next) }
    }
}
