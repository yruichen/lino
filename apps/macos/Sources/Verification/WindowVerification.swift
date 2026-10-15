import AppKit
import WebKit

@MainActor
func verifyWindowLayout(_ controller: EditorWindowController) async throws -> [String] {
    guard let window = controller.window, let content = window.contentView else {
        throw NSError(domain: "WindowVerification", code: 1)
    }
    let original = window.frame
    defer { window.setFrame(original, display: false) }
    window.setContentSize(NSSize(width: 640, height: 420))
    content.layoutSubtreeIfNeeded()
    guard controller.webView.frame.width >= 620, controller.webView.frame.height >= 250,
          content.bounds.contains(controller.webView.frame) else {
        throw NSError(domain: "WindowVerification", code: 2, userInfo: [NSLocalizedDescriptionKey: "最小窗口下编辑区域被原生布局遮挡。"])
    }
    let accepted = await withCheckedContinuation { continuation in
        controller.bridge.command("replace") { continuation.resume(returning: $0) }
    }
    guard accepted else { throw NSError(domain: "WindowVerification", code: 3, userInfo: [NSLocalizedDescriptionKey: "原生替换命令未到达编辑器。"] ) }
    let fits = try await controller.webView.callAsyncJavaScript("""
        const panel = document.querySelector('.ot-search');
        const controls = panel ? [...panel.querySelectorAll('input, button')].filter(node => node.getClientRects().length) : [];
        const fits = controls.length > 0 && controls.every(node => {
            const bounds = node.getBoundingClientRect();
            return bounds.left >= 0 && bounds.right <= innerWidth + 1;
        });
        panel?.querySelector('button[name=close]')?.click();
        return fits;
        """, arguments: [:], in: nil, contentWorld: .page)
    guard fits as? Bool == true else {
        throw NSError(domain: "WindowVerification", code: 4, userInfo: [NSLocalizedDescriptionKey: "最小窗口下查找替换控件溢出。"])
    }
    return ["native-minimum-window-editor-layout", "native-search-command-and-panel-layout"]
}


/// Compose a layout diagnostic from a native view cache and WebKit snapshot.
/// This is not a WindowServer screenshot: inactive/headless native materials
/// may render differently. Use it for geometry, not visual acceptance of chrome.
@MainActor
func captureFixtureWindow(_ controller: EditorWindowController, destination: URL) async throws {
    guard let frame = controller.window?.contentView?.superview,
          let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { throw ImageDataError.invalid }
    frame.cacheDisplay(in: frame.bounds, to: bitmap)
    let image = NSImage(size: frame.bounds.size); image.addRepresentation(bitmap)
    let pane = controller.navigationSplit.editorPane
    let rect = controller.webView.convert(pane.bounds, from: pane).intersection(controller.webView.bounds)
    if !rect.isEmpty {
        let configuration = WKSnapshotConfiguration(); configuration.rect = rect
        let content = try await controller.webView.takeSnapshot(configuration: configuration)
        image.lockFocus(); content.draw(in: frame.convert(rect, from: controller.webView)); image.unlockFocus()
    }
    guard let data = image.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) else { throw ImageDataError.invalid }
    try data.write(to: destination)
}
