import AppKit
import WebKit
import UniformTypeIdentifiers

/// Image files belong to the document, rather than becoming a WebKit navigation.
@MainActor
final class EditorWebView: WKWebView {
    var acceptsImages: (() -> Bool)?
    var onImageDrop: (([String], NSPoint) -> Void)?
    static func images(on board: NSPasteboard) -> [URL] {
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
    }
    private func images(_ info: NSDraggingInfo) -> [URL] { Self.images(on: info.draggingPasteboard) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !images(sender).isEmpty { return acceptsImages?() == true ? .copy : [] }
        return super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if !images(sender).isEmpty { return acceptsImages?() == true }
        return super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = images(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        guard acceptsImages?() == true, let onImageDrop else { return false }
        var point = convert(sender.draggingLocation, from: nil)
        if !isFlipped { point.y = bounds.height - point.y }
        onImageDrop(urls.map(\.path), point)
        return true
    }
}
