import AppKit
import PDFKit

@MainActor
final class LatexPreviewWindowController: NSWindowController {
    private let pdfView = PDFView(frame: .zero)

    init(data: Data, label: String) throws {
        guard let document = PDFDocument(data: data) else {
            throw NSError(domain: "Lino.Latex", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid PDF artifact"])
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = label
        window.minSize = NSSize(width: 520, height: 420)
        super.init(window: window)
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayBox = .mediaBox
        pdfView.document = document
        window.contentView = pdfView
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("Use init(data:label:)") }
}
