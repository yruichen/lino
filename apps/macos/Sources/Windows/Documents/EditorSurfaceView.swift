import AppKit
import WebKit

/// The native loading surface uses the editor's background before WebKit has
/// painted its page. Appearance is always AppKit's effective appearance.
@MainActor
final class EditorSurfaceView: NSView {
    private weak var editor: WKWebView?

    init(editor: WKWebView) {
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        updateBackground()
    }
    required init?(coder: NSCoder) { fatalError("Use init(editor:)") }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateBackground() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateBackground() }

    private func updateBackground() {
        // Keep this initial native surface aligned with --ot-background.
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = dark ? NSColor(srgbRed: 32 / 255, green: 33 / 255, blue: 36 / 255, alpha: 1) : .white
        layer?.backgroundColor = color.cgColor
        window?.backgroundColor = color
        editor?.underPageBackgroundColor = color
    }
}
