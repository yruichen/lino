import AppKit

// Read-only projection of the versioned Rust configuration, not a settings store.
struct EditorPreferences: Codable, Sendable, Equatable {
    var language: String
    var theme: String
    var theme_family: String
    var custom_themes: [ThemeDefinition]
    var background_image: String
    var background_opacity: UInt32
    var surface_opacity: UInt32
    var glass_style: String
    var image_insertion: String
    var body_font: String
    var use_theme_font_size: Bool
    var use_theme_line_height: Bool
    var auto_save: Bool
    var automatic_update_checks: Bool
    var include_prerelease_updates: Bool
    var font_size: UInt32
    var line_height: UInt32
    var page_width: UInt32
    var content_width: String
    var spell_check: Bool
    var continue_lists: Bool
    var code_wrap: Bool
    var code_numbers: Bool
}
struct PreferenceSnapshot: Codable, Sendable {
    let storage_warning: String?
    let schema_version: UInt32
    let revision: String
    var values: EditorPreferences
    func json() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }
}
@MainActor
final class PreferencesCoordinator {
    private let backend: DocumentBackend
    private(set) var snapshot: PreferenceSnapshot?
    private var verificationDirectory: URL?
    init(backend: DocumentBackend) { self.backend = backend }
    static func decode(_ json: String) throws -> PreferenceSnapshot {
        let value = try JSONDecoder().decode(PreferenceSnapshot.self, from: Data(json.utf8))
        guard value.schema_version == 1 else { throw NSError(domain: "Lino", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported preferences schema"] ) }
        return value
    }
    func configure(verifying: Bool) async throws {
        // Obtain defaults from the shared use case even if disk loading fails.
        snapshot = try Self.decode(await backend.perform { try $0.preferences() })
        let directory: URL
        if verifying {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("lino-settings-verify-\(UUID().uuidString)")
            verificationDirectory = directory
        } else {
            directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Lino", isDirectory: true)
        }
        let path = directory.appendingPathComponent("settings.json").path
        let language = verifying ? nil : UserDefaults.standard.string(forKey: "interfaceLanguage")
        let autosave: Bool? = verifying || UserDefaults.standard.object(forKey: "automaticallySaveDocuments") == nil ? nil : UserDefaults.standard.bool(forKey: "automaticallySaveDocuments")
        snapshot = try Self.decode(await backend.perform { try $0.configurePreferences(path: path, legacyLanguage: language, legacyAutosave: autosave) })
        // Migration is complete only after a valid shared file was loaded/written.
        if !verifying {
            UserDefaults.standard.removeObject(forKey: "interfaceLanguage")
            UserDefaults.standard.removeObject(forKey: "automaticallySaveDocuments")
        }
    }
    func update(_ values: EditorPreferences) async throws -> PreferenceSnapshot {
        guard let current = snapshot else { throw NSError(domain: "Lino", code: 1) }
        if current.values == values { return current }
        let json = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
        do {
            let next = try Self.decode(await backend.perform { try $0.updatePreferences(expectedRevision: current.revision, valuesJson: json) })
            snapshot = next; return next
        } catch {
            snapshot = try? Self.decode(await backend.perform { try $0.preferences() })
            throw error
        }
    }
    func cleanupVerificationFiles() {
        if let verificationDirectory { try? FileManager.default.removeItem(at: verificationDirectory) }
    }
}
