import AppKit
import QuartzCore

/// Native controls with an explicit, persistent hit target. The view owns only
/// expansion and focus; the controller forwards queries to the editor.
@MainActor
final class SearchToolbarView: NSView {
    let field = NSSearchField()
    let toggleButton = NSButton()
    var onToggle: (() -> Void)?
    private(set) var expanded = false
    private var width: NSLayoutConstraint!
    private var transition: UInt64 = 0

    override var intrinsicContentSize: NSSize { NSSize(width: expanded ? 260 : 32, height: 32) }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        toggleButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        toggleButton.imagePosition = .imageOnly; toggleButton.bezelStyle = .texturedRounded
        toggleButton.target = self; toggleButton.action = #selector(toggle)
        field.controlSize = .regular; field.font = .systemFont(ofSize: 13)
        field.focusRingType = .none; field.isHidden = true; field.alphaValue = 0
        addSubview(field); addSubview(toggleButton)
        field.translatesAutoresizingMaskIntoConstraints = false
        width = widthAnchor.constraint(equalToConstant: 32)
        NSLayoutConstraint.activate([
            width, heightAnchor.constraint(equalToConstant: 32),
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Native drawing follows the animated bounds, including both
            // rounded ends. A clipped, fixed-width field loses its moving edge.
        ])
    }
    required init?(coder: NSCoder) { fatalError("Use init()") }
    @objc private func toggle() { onToggle?() }
    override func layout() {
        super.layout()
        if expanded, let cell = field.cell as? NSSearchFieldCell {
            // The same hit target covers the field's native magnifying glyph.
            // No second icon or button border sits beside the expanded field.
            toggleButton.frame = field.convert(cell.searchButtonRect(forBounds: field.bounds), to: self)
        } else { toggleButton.frame = NSRect(x: 0, y: 0, width: 32, height: 32) }
    }
    func setExpanded(_ value: Bool, focus: Bool = false) {
        if !value && field.currentEditor() != nil { window?.makeFirstResponder(nil) }
        if value != expanded {
            transition &+= 1; let expected = transition
            let animated = window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            window?.contentView?.layoutSubtreeIfNeeded()
            expanded = value; field.isHidden = false
            toggleButton.isTransparent = false; toggleButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            toggleButton.isBordered = !value; toggleButton.alphaValue = value ? 1 : 0
            let finish: @MainActor @Sendable () -> Void = { [weak self] in
                guard let self, transition == expected else { return }
                field.isHidden = !value; field.alphaValue = value ? 1 : 0
                toggleButton.isTransparent = value; toggleButton.alphaValue = 1
                if value { toggleButton.image = nil }
            }
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2; context.allowsImplicitAnimation = true
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    width.constant = value ? 260 : 32; invalidateIntrinsicContentSize()
                    field.animator().alphaValue = value ? 1 : 0
                    toggleButton.animator().alphaValue = value ? 0 : 1
                    window?.contentView?.layoutSubtreeIfNeeded()
                } completionHandler: { MainActor.assumeIsolated { finish() } }
            } else {
                width.constant = value ? 260 : 32; invalidateIntrinsicContentSize(); finish()
                window?.contentView?.layoutSubtreeIfNeeded()
            }
        }
        if value && focus { window?.makeFirstResponder(field) }
    }
}
