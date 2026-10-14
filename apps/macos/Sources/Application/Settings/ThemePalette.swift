import AppKit

struct ThemeVariant: Codable, Sendable, Equatable {
    var name: String
    var name_en: String
    var colors: [String: String]
    @MainActor var displayName: String { LanguagePreferences.shared.locale == "zh-Hans" ? name : name_en }
}
struct ThemeDefinition: Codable, Sendable, Equatable {
    var schema_version: UInt32
    var id: String
    var name: String
    var font_families: [String]
    var font_size: UInt32
    var line_height: UInt32
    var reading_width: UInt32
    var light: ThemeVariant
    var dark: ThemeVariant
}

/// Immutable bundled catalog + read-only projection of confirmed preferences.
@MainActor
enum ThemePalette {
    static let builtins: [ThemeDefinition] = {
        guard let url = Bundle.main.url(forResource: "classic", withExtension: "json", subdirectory: "Themes"), let data = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([ThemeDefinition].self, from: data) else { preconditionFailure("Missing bundled theme catalog") }
        return values
    }()
    static var current: ThemeDefinition { selected(preferences) }
    private(set) static var preferences: EditorPreferences?
    static var navigationStyle: String { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? "solid" : preferences?.glass_style ?? "solid" }
    static var navigationBackground: NSColor { navigationStyle == "solid" ? color("sidebar").withAlphaComponent(CGFloat(preferences?.surface_opacity ?? 100) / 100) : .clear }
    static func selected(_ values: EditorPreferences?) -> ThemeDefinition {
        (builtins + (values?.custom_themes ?? [])).first { $0.id == values?.theme_family } ?? builtins[0]
    }
    static func install(_ values: EditorPreferences) {
        preferences = values
        AppearanceImage.refresh(values.background_image)
        for window in NSApp.windows {
            window.backgroundColor = color("bg")
            if let root = window.contentView { refresh(root) }
        }
    }
    static func hex(_ raw: String) -> NSColor {
        let value = UInt32(raw.dropFirst(), radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    static func color(_ role: String) -> NSColor {
        return NSColor(name: nil) { appearance in
            MainActor.assumeIsolated {
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let theme = current, palette = dark ? theme.dark : theme.light
                return hex(palette.colors[role] ?? "#000000")
            }
        }
    }
    static func refresh(_ view: NSView) {
        if let field = view as? NSTextField, field.identifier?.rawValue != "theme-preview" {
            let role = field.identifier?.rawValue == "theme-error" ? "error" : (field.font?.pointSize ?? 13) < 12 ? "muted" : "text"
            var parent = field.superview
            while parent != nil && !(parent is NSTableCellView) { parent = parent?.superview }
            field.textColor = parent is NSTableCellView ? (field.font?.pointSize ?? 13) < 12 ? .secondaryLabelColor : .labelColor : color(role)
        }
        if let scroll = view as? NSScrollView, scroll.drawsBackground { scroll.backgroundColor = scroll.documentView is NavigationOutlineView ? navigationBackground : color("sidebar") }
        if let outline = view as? NSOutlineView { outline.backgroundColor = outline is NavigationOutlineView ? navigationBackground : color("sidebar") }
        if let box = view as? ThemeSurface { box.refreshTheme() }
        if let surface = view as? EditorSurfaceView { surface.refreshTheme() }
        view.needsDisplay = true
        for child in view.subviews { refresh(child) }
        if let material = view as? NativeMaterialSurface { material.refreshAppearance() }
    }
}

@MainActor
final class ThemeSurface: NSBox {
    private let role: String
    init(role: String, radius: CGFloat = 0) {
        self.role = role; super.init(frame: .zero)
        boxType = .custom; titlePosition = .noTitle; borderWidth = 0; cornerRadius = radius
        contentViewMargins = .zero; isTransparent = false; refreshTheme()
    }
    required init?(coder: NSCoder) { fatalError("Use init(role:)") }
    func refreshTheme() { fillColor = ThemePalette.color(role) }
}
