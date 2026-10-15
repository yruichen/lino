import AppKit
import WebKit
import PDFKit

@MainActor
final class PrintSurface: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private let resources: URL?
    private var loaded: CheckedContinuation<Void, Error>?
    private var preparing: CheckedContinuation<Void, Error>?
    private var printed: CheckedContinuation<Bool, Never>?
    private var timeout: Task<Void, Never>?
    private var backingWindow: NSWindow?
    private var preparedInfo: NSPrintInfo?
    private var preparedPDF: PDFDocument?
    private var cancelled = false
    private(set) var pageCount = 0

    init(resources: URL? = Bundle.main.resourceURL?.appendingPathComponent("Editor")) {
        self.resources = resources
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.shouldPrintBackgrounds = true
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init(); webView.navigationDelegate = self
    }
    func load(_ html: String) async throws {
        guard !cancelled else { throw CancellationError() }
        try await withCheckedThrowingContinuation { continuation in
            loaded = continuation; startTimeout()
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
    private func startTimeout() {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            self?.abort(NSError(domain: "Lino", code: 1, userInfo: [NSLocalizedDescriptionKey: localized("export.loadTimeout")]))
        }
    }
    private func finishLoad(_ error: Error? = nil) {
        guard let continuation = loaded else { return }; loaded = nil
        timeout?.cancel(); timeout = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard loaded != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await webView.callAsyncJavaScript("await document.fonts.ready; await Promise.all(Array.from(document.images, image => image.decode())); return true;", arguments: [:], in: nil, contentWorld: .page)
                finishLoad()
            } catch { finishLoad(error) }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishLoad(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishLoad(error) }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.navigationType == .other && action.request.url?.scheme == "about" ? .allow : .cancel)
    }

    /// Paged.js runs only in this ephemeral WebKit document. The invisible,
    /// non-key backing window supplies normal layout frames without touching
    /// the editor's view hierarchy or adding a document tab.
    func prepare(info: NSPrintInfo) async throws {
        guard !cancelled else { throw CancellationError() }
        if preparedInfo != nil { return }
        guard let resources else { throw CocoaError(.fileNoSuchFile) }
        let script = try String(contentsOf: resources.appendingPathComponent("print.js"), encoding: .utf8)
        let captured = info.copy() as! NSPrintInfo
        let size = captured.paperSize
        guard [size.width, size.height, captured.topMargin, captured.rightMargin, captured.bottomMargin, captured.leftMargin].allSatisfy({ $0.isFinite && $0 >= 0 }),
              size.width > captured.leftMargin + captured.rightMargin,
              size.height > captured.topMargin + captured.bottomMargin else { throw CocoaError(.coderInvalidValue) }
        let frame = NSRect(x: 0, y: 0, width: size.width * 4 / 3, height: size.height * 4 / 3)
        let canvas = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        canvas.isReleasedWhenClosed = false; canvas.alphaValue = 0; canvas.ignoresMouseEvents = true
        canvas.tabbingMode = .disallowed; canvas.isExcludedFromWindowsMenu = true
        canvas.collectionBehavior = [.transient, .ignoresCycle]
        canvas.contentView = webView; backingWindow = canvas; canvas.orderBack(nil)
        try await withCheckedThrowingContinuation { continuation in
            preparing = continuation; startTimeout()
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await webView.evaluateJavaScript(script + ";window.LinoPrint=LinoPrint;void 0;")
                    let result = try await webView.callAsyncJavaScript("return await window.LinoPrint.paginate(paper);", arguments: ["paper": ["width": size.width, "height": size.height, "top": captured.topMargin, "right": captured.rightMargin, "bottom": captured.bottomMargin, "left": captured.leftMargin]], in: nil, contentWorld: .page) as? [String: Int]
                    guard !cancelled else { throw CancellationError() }
                    guard let count = result?["pages"], count > 0 else { throw CocoaError(.coderInvalidValue) }
                    // CSS pixels are 96/in; native PDF points are 72/in. Use
                    // WebKit's vector PDF API rather than its integer AppKit
                    // print rectangles, which truncate fractional page edges.
                    webView.pageZoom = 72 / 96
                    let origins = try await webView.callAsyncJavaScript("return [...document.querySelectorAll('.pagedjs_page')].map(page => page.getBoundingClientRect().top);", arguments: [:], in: nil, contentWorld: .page) as? [Double]
                    guard let origins, origins.count == count else { throw CocoaError(.coderInvalidValue) }
                    let document = PDFDocument()
                    for origin in origins {
                        guard !cancelled else { throw CancellationError() }
                        let configuration = WKPDFConfiguration()
                        configuration.rect = CGRect(x: 0, y: origin * 72 / 96, width: size.width, height: size.height)
                        let data = try await webView.pdf(configuration: configuration)
                        guard !cancelled else { throw CancellationError() }
                        guard let single = PDFDocument(data: data), single.pageCount == 1, let page = single.page(at: 0) else { throw CocoaError(.coderInvalidValue) }
                        document.insert(page, at: document.pageCount)
                    }
                    pageCount = count; preparedInfo = captured; preparedPDF = document; finishPreparation()
                } catch { finishPreparation(error) }
            }
        }
    }
    private func finishPreparation(_ error: Error? = nil) {
        guard let continuation = preparing else { return }; preparing = nil
        timeout?.cancel(); timeout = nil; backingWindow?.orderOut(nil)
        if let error { closeCanvas(); continuation.resume(throwing: error) } else { continuation.resume() }
    }
    private func closeCanvas() {
        webView.removeFromSuperview(); backingWindow?.close(); backingWindow = nil
    }

    /// PDFKit retains WebKit's native pages and annotations without redrawing
    /// them, and prints those same pages for a physical printer.
    func print(in window: NSWindow, info: NSPrintInfo, pdf: URL?) async -> Bool {
        do { try await prepare(info: info) } catch { return false }
        guard !cancelled, let preparedInfo, let document = preparedPDF, document.pageCount == pageCount else { return false }
        defer { closeCanvas(); preparedPDF = nil }
        if let pdf {
            guard let data = document.dataRepresentation() else { return false }
            do { try data.write(to: pdf, options: .atomic); return true } catch { return false }
        }
        let printerInfo = preparedInfo.copy() as! NSPrintInfo
        printerInfo.topMargin = 0; printerInfo.rightMargin = 0; printerInfo.bottomMargin = 0; printerInfo.leftMargin = 0
        guard let printer = document.printOperation(for: printerInfo, scalingMode: .pageScaleToFit, autoRotate: true) else { return false }
        printer.showsPrintPanel = true; printer.showsProgressPanel = true
        // Keep the native PDF document alive through the asynchronous operation.
        let completed = await run(printer, in: window)
        withExtendedLifetime(document) {}
        return completed
    }
    private func run(_ operation: NSPrintOperation, in window: NSWindow) async -> Bool {
        await withCheckedContinuation { continuation in
            printed = continuation
            operation.runModal(for: window, delegate: self, didRun: #selector(didPrint(_:success:context:)), contextInfo: nil)
        }
    }
    @objc nonisolated private func didPrint(_ operation: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let continuation = printed; printed = nil; continuation?.resume(returning: success)
        }
    }
    private func abort(_ error: Error) {
        cancelled = true; finishLoad(error); finishPreparation(error)
        // Navigation discards pending page-layout callbacks in the old document.
        if printed == nil {
            webView.evaluateJavaScript("window.LinoPrint?.cancel()", completionHandler: nil)
            webView.stopLoading(); webView.loadHTMLString("<html></html>", baseURL: nil); closeCanvas()
        }
    }
    func cancel() { abort(CancellationError()) }
}
