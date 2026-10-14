import AppKit

/// The same native material and selected backdrop used by the editor.
@MainActor
final class AppearancePreviewView: NSView {
    private let backdrop = NSImageView()
    private let material = NativeMaterialSurface(radius: 16)
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 10; layer?.masksToBounds = true
        let color = ThemePalette.color("bg")
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = color.cgColor }
        backdrop.image = AppearanceImage.image; backdrop.imageScaling = .scaleProportionallyUpOrDown
        backdrop.alphaValue = CGFloat(ThemePalette.preferences?.background_opacity ?? 20) / 100
        addSubview(backdrop); addSubview(material)
        let title = NSTextField(labelWithString: "Lino"), detail = NSTextField(labelWithString: localized("settings.preview"))
        title.font = .systemFont(ofSize: 16, weight: .semibold); title.textColor = ThemePalette.color("text")
        detail.font = .systemFont(ofSize: 11); detail.textColor = ThemePalette.color("muted")
        let stack = NSStackView(views: [title, detail]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 5
        let padded = NSView(); padded.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: padded.leadingAnchor, constant: 16), stack.centerYAnchor.constraint(equalTo: padded.centerYAnchor)])
        material.install(padded)
        heightAnchor.constraint(equalToConstant: 132).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func layout() {
        super.layout(); backdrop.frame = bounds
        material.frame = NSRect(x: 16, y: 24, width: 170, height: 84)
    }
}
