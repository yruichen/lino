import AppKit
import WebKit

/// Only the themed loading color is native. The editor page owns its wallpaper;
/// the window is presented after that page has applied its confirmed appearance.
@MainActor
final class EditorSurfaceView: NSView {
    private weak var editor: WKWebView?
    init(editor: WKWebView) {
        self.editor = editor
        super.init(frame: .zero); wantsLayer = true; refreshTheme()
    }
    required init?(coder: NSCoder) { fatalError("Use init(editor:)") }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshTheme() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshTheme() }
    func refreshTheme() {
        let color = ThemePalette.color("bg")
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let resolved = color.usingColorSpace(.sRGB) ?? color
            layer?.backgroundColor = resolved.cgColor
            editor?.underPageBackgroundColor = resolved
        }
        window?.backgroundColor = color
    }
}
