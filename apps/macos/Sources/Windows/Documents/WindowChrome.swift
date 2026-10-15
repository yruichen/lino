import AppKit

/// Keep content below AppKit's native titlebar and unified toolbar. The system
/// owns its material, control groups, window buttons and active-window behavior.
@MainActor
func installWindowChrome(in window: NSWindow, content: NSView) -> NSLayoutGuide {
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarAppearsTransparent = true; window.titlebarSeparatorStyle = .none
    return window.contentLayoutGuide as! NSLayoutGuide
}
