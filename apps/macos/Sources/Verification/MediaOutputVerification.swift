import AppKit
import CoreGraphics

@MainActor
func verifyMediaOutput(_ windows: DocumentWindows) async throws -> [String] {
    var passed: [String] = []
    func check(_ name: String, _ condition: Bool) throws {
        guard condition else { throw NSError(domain: "MediaOutputVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
        passed.append(name)
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lino-media-output-\(UUID().uuidString)")
    let noteDirectory = directory.appendingPathComponent("v11"), imageDirectory = directory.appendingPathComponent("figures")
    try FileManager.default.createDirectory(at: noteDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
    let picture = imageDirectory.appendingPathComponent("Figure.png"), note = noteDirectory.appendingPathComponent("Paper.md")
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 12, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for y in 0..<12 { for x in 0..<12 { bitmap.setColor(.systemOrange, atX: x, y: y) } }
    try bitmap.representation(using: .png, properties: [:])!.write(to: picture)
    let raw = "# Research\n\nA result $E_r=\\mathcal{L}^{\\mathrm{rgb}}_r + \\lambda_g\\mathcal{L}^{\\mathrm{geo}}_r$ in the text.\n\n![Figure](../figures/Figure.png)\n\n| Model | Result |\n| --- | --- |\n| **Ours** | <u>37.5</u> |\n\n" + String(repeating: "A paragraph for pagination and a stable writing surface.\n\n", count: 55)
    try Data(raw.utf8).write(to: note)
    let preferences = try PreferencesCoordinator.decode(await windows.backend.perform { try $0.preferences() })
    ThemePalette.install(preferences.values)
    let document = windows.create(path: note.path)
    defer { document.detach(); document.documents.cleanupVerificationFiles(); document.window?.close(); try? FileManager.default.removeItem(at: directory) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !document.documents.ready, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    guard document.documents.ready, let window = document.window else { throw NSError(domain: "MediaOutputVerification", code: 2) }
    window.makeKeyAndOrderFront(nil)
    let ready = try await document.webView.callAsyncJavaScript("const end=Date.now()+5000; while(Date.now()<end){const i=document.querySelector('.ot-preview-image img'), m=document.querySelector('.ot-preview-math'); if(i?.complete&&i.naturalWidth&&m?.dataset.previewState==='ready') return true; await new Promise(r=>setTimeout(r,20));} return false;", arguments: [:], in: nil, contentWorld: .page) as? Bool == true
    try check("document-relative-parent-image-loads-through-real-resource-scheme", ready)
    let media = try await document.webView.callAsyncJavaScript("const m=document.querySelector('.ot-preview-inline.ot-preview-math .ot-preview-content'); const s=getComputedStyle(m); return {inline:s.overflowX==='visible'&&s.overflowY==='visible'&&!!m.querySelector('.katex'), bold:document.querySelector('.table-cell-preview strong')?.textContent==='Ours', underline:document.querySelector('.table-cell-preview u')?.textContent==='37.5'};", arguments: [:], in: nil, contentWorld: .page) as? [String: Bool] ?? [:]
    try check("real-inline-formula-has-no-scroll-container", media["inline"] == true)
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
