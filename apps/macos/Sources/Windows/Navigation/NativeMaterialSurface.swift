import AppKit

/// AppKit owns material/content geometry; the parent owns only this surface's frame.
@MainActor
final class NativeMaterialSurface: NSView {
    private let content = NSView()
    private let paint: ThemeSurface
    private var material: NSView?
    private var installedStyle = ""
    private var installation: [NSLayoutConstraint] = []
    private let radius: CGFloat
    init(radius: CGFloat = 0) {
        self.radius = radius
        paint = ThemeSurface(role: "sidebar", radius: radius)
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        refreshAppearance()
    }
    required init?(coder: NSCoder) { fatalError("Use init(radius:)") }
    private func fill(_ child: NSView, in parent: NSView) -> [NSLayoutConstraint] {
        child.translatesAutoresizingMaskIntoConstraints = false
        return [child.leadingAnchor.constraint(equalTo: parent.leadingAnchor), child.trailingAnchor.constraint(equalTo: parent.trailingAnchor), child.topAnchor.constraint(equalTo: parent.topAnchor), child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)]
    }
    func install(_ view: NSView) {
        content.addSubview(view)
        NSLayoutConstraint.activate(fill(view, in: content))
    }
    func refreshAppearance() {
        let values = ThemePalette.preferences
        let style = ThemePalette.navigationStyle
        var color = NSColor.clear
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = ThemePalette.color("sidebar").usingColorSpace(.sRGB) ?? .clear
        }
        let opacity = CGFloat(values?.surface_opacity ?? 100) / 100
        if style != installedStyle {
            NSLayoutConstraint.deactivate(installation); installation = []
            if #available(macOS 26, *), let glass = material as? NSGlassEffectView { glass.contentView = nil }
            content.removeFromSuperview(); material?.removeFromSuperview(); paint.removeFromSuperview(); material = nil
            if style == "solid" {
                addSubview(paint); addSubview(content)
                installation = fill(paint, in: self) + fill(content, in: self)
            } else if #available(macOS 26, *) {
                let glass = NSGlassEffectView(); glass.cornerRadius = radius
                glass.contentView = content; material = glass; addSubview(glass)
                installation = fill(glass, in: self)
            } else {
                let effect = NSVisualEffectView(); effect.material = .sidebar
                effect.blendingMode = .behindWindow; effect.state = .followsWindowActiveState
                effect.addSubview(content); material = effect; addSubview(effect)
                installation = fill(effect, in: self) + fill(content, in: effect)
            }
            NSLayoutConstraint.activate(installation)
            installedStyle = style
        }
        paint.fillColor = color.withAlphaComponent(opacity)
        if #available(macOS 26, *), let glass = material as? NSGlassEffectView {
            glass.style = style == "clear" ? .clear : .regular
            glass.tintColor = color.withAlphaComponent(opacity * (style == "clear" ? 0.12 : 0.35))
        }
        needsDisplay = true
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshAppearance() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshAppearance() }
}
