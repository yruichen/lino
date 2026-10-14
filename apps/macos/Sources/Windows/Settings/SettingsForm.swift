import AppKit

/// A scroll document starts at its top even when the form is shorter than the viewport.
@MainActor
final class SettingsPageStack: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
enum SettingsForm {
    static func label(_ key: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: localized(key)); field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = ThemePalette.color(size < 13 ? "muted" : "text"); return field
    }
    static func stack(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }
    static func row(_ key: String, _ control: NSView) -> NSStackView {
        let label = label(key)
        let row = NSStackView(views: [label, NSView(), control]); row.alignment = .centerY; row.spacing = 16
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 168).isActive = true
        return row
    }
    static func group(_ key: String, _ views: [NSView], detail: String? = nil) -> NSStackView {
        let box = ThemeSurface(role: "surface", radius: 8)
        let form = stack(views, spacing: 8); form.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(form)
        NSLayoutConstraint.activate([form.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16), form.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16), form.topAnchor.constraint(equalTo: box.topAnchor, constant: 12), form.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12)])
        var content: [NSView] = [label(key, size: 12, weight: .semibold), box]
        if let detail { content.append(label(detail, size: 11)) }
        return stack(content, spacing: 8)
    }
}
