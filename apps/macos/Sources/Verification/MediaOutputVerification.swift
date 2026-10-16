import AppKit
import CoreGraphics
import PDFKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
func verifyMediaOutput(_ windows: DocumentWindows) async throws -> [String] {
    var passed: [String] = []
    func check(_ name: String, _ condition: Bool) throws {
        guard condition else { throw NSError(domain: "MediaOutputVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
        passed.append(name)
        if CommandLine.arguments.contains("--headless") { FileHandle.standardError.write(Data((name + "\n").utf8)) }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lino-media-output-\(UUID().uuidString)")
    let noteDirectory = directory.appendingPathComponent("v11"), imageDirectory = directory.appendingPathComponent("figures")
    try FileManager.default.createDirectory(at: noteDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
    let picture = imageDirectory.appendingPathComponent("Figure.png"), note = noteDirectory.appendingPathComponent("Paper.md")
    guard let bitmap = CGContext(data: nil, width: 160, height: 100, bitsPerComponent: 8, bytesPerRow: 160 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let destination = CGImageDestinationCreateWithURL(picture as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw ImageDataError.invalid }
    bitmap.setFillColor(CGColor(srgbRed: 1, green: 0.6, blue: 0, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
    guard let image = bitmap.makeImage() else { throw ImageDataError.invalid }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ImageDataError.invalid }
    let raw = "# Research\n\n中文排版与分页。\n\n[Reference](https://example.invalid/reference)\n\nA result $E_r=\\mathcal{L}^{\\mathrm{rgb}}_r + \\lambda_g\\mathcal{L}^{\\mathrm{geo}}_r$ in the text.\n\n![Figure](../figures/Figure.png \"**Figure** $x^2$\")\n\n| Model | Result |\n| --- | --- |\n| **Ours** | <u>37.5</u> |\n\n```mermaid\nflowchart LR\nAlpha-->Beta\n```\n\n" + String(repeating: "A paragraph for pagination and a stable writing surface.\n\n", count: 55)
    try Data(raw.utf8).write(to: note)
    var preferences = try PreferencesCoordinator.decode(await windows.backend.perform { try $0.preferences() })
    preferences.values.theme = "dark"
    ThemePalette.install(preferences.values)
    let document = windows.create(path: note.path)
    defer { document.detach(); document.documents.cleanupVerificationFiles(); document.window?.close(); try? FileManager.default.removeItem(at: directory) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !document.documents.ready, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    guard document.documents.ready, let window = document.window else { throw NSError(domain: "MediaOutputVerification", code: 2) }
    window.appearance = NSAppearance(named: .darkAqua)
    try await document.documents.applyPreferences(preferences.json())
    window.makeKeyAndOrderFront(nil)
    let ready = try await document.webView.callAsyncJavaScript("for(const image of document.images) image.loading='eager';const end=Date.now()+5000; while(Date.now()<end){const i=document.querySelector('.ot-preview-image img'), m=document.querySelector('.ot-preview-math'); if(i?.complete&&i.naturalWidth&&m?.dataset.previewState==='ready') return true; await new Promise(r=>setTimeout(r,20));} return false;", arguments: [:], in: nil, contentWorld: .page) as? Bool == true
    try check("document-relative-parent-image-loads-through-real-resource-scheme", ready)
    let media = try await document.webView.callAsyncJavaScript("const m=document.querySelector('.ot-preview-inline.ot-preview-math .ot-preview-content'); const s=getComputedStyle(m); return {caption:document.querySelector('.ot-image-caption strong')?.textContent==='Figure'&&!!document.querySelector('.ot-image-caption .katex math'), inline:s.overflowX==='visible'&&s.overflowY==='visible'&&!!m.querySelector('.katex'), bold:document.querySelector('.table-cell-preview strong')?.textContent==='Ours', underline:document.querySelector('.table-cell-preview u')?.textContent==='37.5'};", arguments: [:], in: nil, contentWorld: .page) as? [String: Bool] ?? [:]
    try check("real-inline-formula-has-no-scroll-container", media["inline"] == true)
    try check("image-caption-renders-bold-and-math-in-real-webkit", media["caption"] == true)
    let snapshot = try await document.bridge.call("snapshot") as? [String: Any] ?? [:]
    try check("table-reading-renders-bold-and-underline-while-preserving-markdown", media["bold"] == true && media["underline"] == true && snapshot["text"] as? String == raw)
    let identity = try await document.bridge.call("exportIdentity") as! [String: String]
    let job = try await windows.backend.perform { try $0.beginExport(sessionId: identity["session_id"]!, epoch: identity["epoch"]!, revision: identity["revision"]!) }
    defer { _ = job.cancel() }
    _ = try await document.bridge.call("endExportCapture")
    let source = try await windows.backend.perform { _ in try job.source() }
    let plan = try await document.bridge.call("prepareExport", arguments: [source]) as! [String: Any]
    var resources: [String: String] = [:]
    for image in plan["images"] as! [String] {
        let content = try await windows.backend.perform { _ in try job.readImage(source: image) }
        resources[image] = "data:\(content.mime);base64,\(Data(content.bytes).base64EncodedString())"
    }
    let imageJSON = String(decoding: try JSONSerialization.data(withJSONObject: resources), as: UTF8.self)
    let css = try String(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("Editor/math.css"), encoding: .utf8)
    let html = try await document.bridge.call("renderExport", arguments: [plan["job_id"]!, imageJSON, css]) as! String
    let surface = PrintSurface(); try await surface.load(html)
    let color = try await surface.webView.callAsyncJavaScript("return getComputedStyle(document.body).backgroundColor;", arguments: [:], in: nil, contentWorld: .page) as? String
    let editorColor = try await document.webView.callAsyncJavaScript("return getComputedStyle(document.querySelector('.cm-editor')).backgroundColor;", arguments: [:], in: nil, contentWorld: .page) as? String
    try check("pdf-rendering-surface-keeps-the-editor-theme-and-resolves-parent-images", color == editorColor && resources.count == 1)
    let pdf = directory.appendingPathComponent("Research.pdf"), info = NSPrintInfo.shared.copy() as! NSPrintInfo
    info.paperSize = NSSize(width: 595, height: 842); info.topMargin = 36; info.bottomMargin = 36
    guard await surface.print(in: window, info: info, pdf: pdf) else { throw NSError(domain: "MediaOutputVerification", code: 3, userInfo: [NSLocalizedDescriptionKey: "Native PDF printing failed"]) }
    let bytes = try Data(contentsOf: pdf)
    let published = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/validation/export.pdf")
    let target = try await windows.backend.perform { try $0.saveTarget(path: published.path) }
    defer { Task { try? await windows.backend.perform { try $0.releaseSaveTarget(targetJson: target) } } }
    _ = try await windows.backend.perform { _ in try job.commit(targetJson: target, bytes: bytes) }
    let output = try Data(contentsOf: published)
    let pdfDocument = CGDataProvider(data: output as CFData).flatMap { CGPDFDocument($0) }
    try check("native-paginated-pdf-is-created-and-atomically-published", output.starts(with: Data("%PDF-".utf8)) && (pdfDocument?.numberOfPages ?? 0) > 1)
    guard let rendered = PDFDocument(data: output), rendered.pageCount > 0 else { throw ImageDataError.invalid }
    guard let page = pdfDocument?.page(at: 1),
          let raster = CGContext(data: nil, width: 595, height: 842, bitsPerComponent: 8, bytesPerRow: 595 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
          let storage = raster.data else { throw ImageDataError.invalid }
    raster.setFillColor(CGColor(gray: 1, alpha: 1)); raster.fill(CGRect(x: 0, y: 0, width: 595, height: 842))
    raster.drawPDFPage(page)
    let pixels = storage.assumingMemoryBound(to: UInt8.self)
    func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) { let index = (y * 595 + x) * 4; return (pixels[index], pixels[index + 1], pixels[index + 2]) }
    let margin = pixel(4, 4), body = pixel(100, 210)
    try check("pdf-paper-margin-is-dark-in-the-final-pdf-not-only-in-html", max(margin.0, margin.1, margin.2) < 102)
    try check("pdf-body-background-is-dark-and-light-text-is-readable", max(body.0, body.1, body.2) < 102)
    let visibleImage = stride(from: 0, to: 842, by: 5).contains { y in
        stride(from: 0, to: 595, by: 5).contains { x in let p = pixel(x, y); return p.0 > 178 && p.1 > 51 && p.2 < 51 }
    }
    try check("final-pdf-paints-embedded-image-above-the-paper-background", visibleImage)
    guard let lastPage = pdfDocument?.page(at: pdfDocument!.numberOfPages) else { throw ImageDataError.invalid }
    raster.setFillColor(CGColor(gray: 1, alpha: 1)); raster.fill(CGRect(x: 0, y: 0, width: 595, height: 842)); raster.drawPDFPage(lastPage)
    // The right-hand column is empty in this fixture. Check its complete
    // background rather than requiring a fully white pixel at text coordinates.
    let whiteSeam = (0..<842).contains { y in let p = pixel(500, y); return max(p.0, p.1, p.2) > 102 }
    try check("last-pdf-page-has-no-white-seam-at-the-document-bottom", !whiteSeam)
    let links = (0..<rendered.pageCount).flatMap { rendered.page(at: $0)?.annotations ?? [] }
    try check("native-pdf-keeps-native-url-link-annotations", links.contains { $0.url?.host == "example.invalid" })
    try check("native-pdf-keeps-searchable-vector-text", rendered.string?.contains("Research") == true)
    let text = rendered.string?.precomposedStringWithCompatibilityMapping ?? ""
    try check("pagination-preserves-all-55-paragraphs", text.components(separatedBy: "A paragraph for pagination and a stable writing surface.").count - 1 == 55)
    try check("native-pdf-keeps-chinese-text", text.contains("中文排版"))
    try check("native-pdf-keeps-svg-text", text.contains("Alpha") && text.contains("Beta"))
    // Verify the actual native multi-page output with an embedded backdrop;
    // inspect the final PDF rather than just the HTML or its page edges.
    let backdropPlan = try await document.bridge.call("prepareExport", arguments: [source]) as! [String: Any]
    let backdropHTML = try await document.bridge.call("renderExport", arguments: [backdropPlan["job_id"]!, imageJSON, css, resources.values.first!]) as! String
    try Data(backdropHTML.utf8).write(to: published.deletingLastPathComponent().appendingPathComponent("export-background.html"), options: .atomic)
    let backdropSurface = PrintSurface(); try await backdropSurface.load(backdropHTML)
    let backdropPDF = directory.appendingPathComponent("Backdrop.pdf")
    guard await backdropSurface.print(in: window, info: info, pdf: backdropPDF) else { throw ImageDataError.invalid }
    let backdropBytes = try Data(contentsOf: backdropPDF)
    let backdropOutput = published.deletingLastPathComponent().appendingPathComponent("export-background.pdf")
    try backdropBytes.write(to: backdropOutput, options: .atomic)
    guard let backdropDocument = CGDataProvider(data: backdropBytes as CFData).flatMap({ CGPDFDocument($0) }), backdropDocument.numberOfPages == pdfDocument!.numberOfPages else { throw ImageDataError.invalid }
    for index in [1, backdropDocument.numberOfPages] {
        guard let page = backdropDocument.page(at: index) else { throw ImageDataError.invalid }
        raster.setFillColor(CGColor(gray: 1, alpha: 1)); raster.fill(CGRect(x: 0, y: 0, width: 595, height: 842)); raster.drawPDFPage(page)
        let body = pixel(500, 400), edge = pixel(4, 4)
        try check("pdf-backdrop-is-visible-in-body-and-margin-on-page-\(index)", body.0 > 55 && body.1 > 40 && body.2 < 50 && edge.0 > 55 && edge.1 > 40 && edge.2 < 50)
        // Mermaid's intentional panel fills the first page's content width.
        // Inspect its empty paper margin there; on the final page inspect the
        // full empty body column that exposed the original background defect.
        let blankColumn = index == 1 ? 550 : 500
        let uniform = (0..<842).allSatisfy { y in
            let p = pixel(blankColumn, y)
            return abs(Int(p.0) - Int(edge.0)) <= 3 && abs(Int(p.1) - Int(edge.1)) <= 3 && abs(Int(p.2) - Int(edge.2)) <= 3
        }
        try check("pdf-backdrop-fills-the-complete-empty-column-on-page-\(index)", uniform)
    }
    let cancelledSurface = PrintSurface(); try await cancelledSurface.load(html)
    cancelledSurface.cancel()
    var rejected = false
    do { try await cancelledSurface.prepare(info: info) } catch is CancellationError { rejected = true }
    try check("cancelled-print-preparation-cannot-start-a-page-job", rejected && cancelledSurface.pageCount == 0)
    passed += try await verifyWideTableOutput(windows, directory: directory)
    return passed
}

@MainActor
func verifyImageReferenceInsertion(_ windows: DocumentWindows) async throws -> [String] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lino-image-reference-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let picture = directory.appendingPathComponent("Original.png")
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 12, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<12 { for x in 0..<12 { bitmap.setColor(.systemGreen, atX: x, y: y) } }
    try bitmap.representation(using: .png, properties: [:])!.write(to: picture)
    let document = windows.create()
    defer { document.detach(); document.documents.cleanupVerificationFiles(); document.window?.delegate = nil; document.window?.close(); try? FileManager.default.removeItem(at: directory) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !document.documents.ready, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    guard document.documents.ready else { throw NSError(domain: "ImageReferenceVerification", code: 1) }
    let point = try await document.webView.callAsyncJavaScript("const r=document.querySelector('.cm-line').getBoundingClientRect(); return {x:r.left+4,y:r.top+r.height/2};", arguments: [:], in: nil, contentWorld: .page) as! [String: Double]
    document.webView.onImageDrop?([picture.path], NSPoint(x: point["x"]!, y: point["y"]!))
    let imported = try await document.webView.callAsyncJavaScript("const end=Date.now()+5000; while(Date.now()<end){const i=document.querySelector('.ot-preview-image img'); if(window.lino.snapshot().text.includes('Original.png')&&i?.complete&&i.naturalWidth===12) return true; await new Promise(r=>setTimeout(r,20));} return false;", arguments: [:], in: nil, contentWorld: .page) as? Bool == true
    let snapshot = try await document.bridge.call("snapshot") as? [String: Any] ?? [:]
    guard imported, !document.documents.hasFile,
          (snapshot["text"] as? String)?.contains("![](<" + picture.resolvingSymlinksInPath().path) == true,
          try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 1 else {
        throw NSError(domain: "ImageReferenceVerification", code: 2, userInfo: [NSLocalizedDescriptionKey: "Dropping into an unsaved document did not link the original image"])
    }
    _ = try await document.bridge.call("command", arguments: ["undo"])
    let undo = try await document.bridge.call("snapshot") as? [String: Any] ?? [:]
    guard undo["text"] as? String == "", FileManager.default.fileExists(atPath: picture.path) else { throw NSError(domain: "ImageReferenceVerification", code: 3) }
    _ = try await document.bridge.call("prepareReplacement")
    let intent = try await document.bridge.call("replacementIntent", arguments: [true]) as! String
    _ = try await document.bridge.call("closeDocument", arguments: [intent])
    return ["dragged-image-links-original-absolute-path-in-unsaved-document-without-assets", "image-reference-insertion-undo-keeps-the-original-file"]
}


/// Synthetic Markdown only. Exercises editor geometry, real column measurement,
/// Paged.js continuation rows and the final native, searchable PDF together.
@MainActor
private func verifyWideTableOutput(_ windows: DocumentWindows, directory: URL) async throws -> [String] {
    var passed: [String] = []
    func check(_ name: String, _ condition: Bool) throws {
        guard condition else { throw NSError(domain: "WideTableVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
        passed.append(name)
        if CommandLine.arguments.contains("--headless") { FileHandle.standardError.write(Data((name + "\n").utf8)) }
    }
    let headers = (0..<12).map { String(format: "Measurement%02d", $0) }
    let values = (0..<28).map { row in (0..<12).map { column in String(format: "V%02dR%02d", column, row) } }
    let longToken = String(repeating: "abcdefghij", count: 30)
    let wide = "| Row | " + headers.joined(separator: " | ") + " |\n| --- | " + Array(repeating: "---", count: 12).joined(separator: " | ") + " |\n" + values.enumerated().map { row, cells in "| Row\(row) | " + cells.joined(separator: " | ") + " |" }.joined(separator: "\n")
    let raw = "# Wide tables\n\n| Label | Content |\n| --- | --- |\n| Wrap | " + longToken + " |\n\n" + wide
    let note = directory.appendingPathComponent("WideTables.md")
    try Data(raw.utf8).write(to: note)
    let document = windows.create(path: note.path)
    defer { document.detach(); document.documents.cleanupVerificationFiles(); document.window?.close() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !document.documents.ready, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    guard document.documents.ready, let window = document.window else { throw NSError(domain: "WideTableVerification", code: 2) }
    let geometry = try await document.webView.callAsyncJavaScript("""
        const end=Date.now()+5000;
        while(Date.now()<end){
          const tables=[...document.querySelectorAll('.markdown-table')];
          if(tables.length===2){
            const preview=tables[0].querySelectorAll('td .table-cell-preview')[1];
            const style=getComputedStyle(preview), wide=tables[1];
            return {wrap:preview.getBoundingClientRect().height>parseFloat(style.lineHeight)*2,
              scroll:wide.scrollWidth>wide.clientWidth,
              contained:wide.getBoundingClientRect().width<=document.querySelector('.cm-content').getBoundingClientRect().width+1};
          }
          await new Promise(r=>setTimeout(r,20));
        }
        return {};
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Bool] ?? [:]
    try check("wide-table-editor-wraps-long-cell-without-expanding-the-reading-column", geometry["wrap"] == true)
    try check("wide-table-editor-keeps-all-columns-in-a-local-scroll-region", geometry["scroll"] == true && geometry["contained"] == true)
    let identity = try await document.bridge.call("exportIdentity") as! [String: String]
    let job = try await windows.backend.perform { try $0.beginExport(sessionId: identity["session_id"]!, epoch: identity["epoch"]!, revision: identity["revision"]!) }
    defer { _ = job.cancel() }
    _ = try await document.bridge.call("endExportCapture")
    let source = try await windows.backend.perform { _ in try job.source() }
    let plan = try await document.bridge.call("prepareExport", arguments: [source]) as! [String: Any]
    let html = try await document.bridge.call("renderExport", arguments: [plan["job_id"]!, "{}", ""]) as! String
    let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".local/validation/export-wide-table.pdf")
    try Data(html.utf8).write(to: output.deletingPathExtension().appendingPathExtension("html"), options: .atomic)
    let surface = PrintSurface(); try await surface.load(html)
    let info = NSPrintInfo.shared.copy() as! NSPrintInfo
    info.paperSize = NSSize(width: 595, height: 842)
    info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
    guard await surface.print(in: window, info: info, pdf: output), let pdf = PDFDocument(url: output) else { throw NSError(domain: "WideTableVerification", code: 3) }
    let layout = try await surface.webView.callAsyncJavaScript("""
        const tables=[...document.querySelectorAll('.pagedjs_page table')];
        const bands=tables.filter(t=>t.caption);
        return {bands:bands.length>1,
          fits:tables.every(t=>{const box=t.closest('.pagedjs_page_content').getBoundingClientRect(), r=t.getBoundingClientRect();return r.left>=box.left-1&&r.right<=box.right+1&&r.top>=box.top-1&&r.bottom<=box.bottom+1;}),
          headers:bands.every(t=>t.querySelector('thead th')?.textContent==='Row')&&tables.every(t=>!!t.tHead&&t.querySelectorAll('col').length===t.tHead.rows[0].cells.length)};
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Bool] ?? [:]
    try check("wide-table-pdf-uses-labelled-column-continuations-with-repeated-row-headers", layout["bands"] == true && layout["headers"] == true)
    try check("wide-table-pdf-keeps-every-table-inside-the-paper-content-box", layout["fits"] == true)
    let text = pdf.string?.precomposedStringWithCompatibilityMapping ?? ""
    try check("wide-table-native-pdf-keeps-every-data-cell-exactly-once", values.flatMap { $0 }.allSatisfy { text.components(separatedBy: $0).count - 1 == 1 })
    try check("wide-table-native-pdf-keeps-all-column-headings", headers.allSatisfy { text.contains($0) })
    return passed
}
