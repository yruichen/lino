import AppKit

/// Theme choice is a standard radio button. Previews are separate content,
/// so AppKit's button bezel never clips or scales the palette sample.
@MainActor
final class ThemeChoiceButton: NSButton {
    let definition: ThemeDefinition
    var chosen = false { didSet { state = chosen ? .on : .off } }
    init(_ definition: ThemeDefinition, target: AnyObject, action: Selector) {
        self.definition = definition; super.init(frame: .zero)
        self.target = target; self.action = action
        setButtonType(.radio)
        title = definition.light.displayName + " / " + definition.dark.displayName
        font = .systemFont(ofSize: 13)
        setAccessibilityLabel(title)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("Use init(definition:)") }

    static func preview(_ variant: ThemeVariant, theme: ThemeDefinition) -> NSBox {
        let box = NSBox()
        box.boxType = .custom; box.titlePosition = .noTitle
        box.contentViewMargins = .zero; box.isTransparent = false
        box.cornerRadius = 4; box.borderWidth = 1
        box.borderColor = ThemePalette.hex(variant.colors["border"]!)
        box.fillColor = ThemePalette.hex(variant.colors["bg"]!)
        box.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "Aa")
        label.identifier = NSUserInterfaceItemIdentifier("theme-preview")
        label.font = theme.font_families.compactMap { NSFont(name: $0, size: 20) }.first ?? .systemFont(ofSize: 20)
        label.textColor = ThemePalette.hex(variant.colors["heading"]!)
        label.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(label)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 92), box.heightAnchor.constraint(equalToConstant: 36),
            label.centerXAnchor.constraint(equalTo: box.centerXAnchor), label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        box.toolTip = variant.displayName; box.setAccessibilityLabel(variant.displayName)
        return box
    }
}
