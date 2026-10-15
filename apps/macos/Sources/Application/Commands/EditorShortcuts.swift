import AppKit

/// Both the menus and editor consume the registry generated from protocol.
enum EditorShortcuts {
    struct Binding: Decodable { let command: String; let key: String; let modifiers: [String] }
    static let bindings: [Binding] = {
        guard let url = Bundle.main.url(forResource: "EditorShortcuts", withExtension: "json"), let bytes = try? Data(contentsOf: url), let value = try? JSONDecoder().decode([Binding].self, from: bytes) else { return [] }
        return value
    }()
    @MainActor static func apply(_ command: String, to item: NSMenuItem) {
        guard let binding = bindings.first(where: { $0.command == command }) else { return }
        item.keyEquivalent = binding.key
        item.keyEquivalentModifierMask = binding.modifiers.reduce(into: NSEvent.ModifierFlags()) { flags, modifier in
            switch modifier { case "command": flags.insert(.command); case "shift": flags.insert(.shift); case "option": flags.insert(.option); case "control": flags.insert(.control); default: break }
        }
    }
}
