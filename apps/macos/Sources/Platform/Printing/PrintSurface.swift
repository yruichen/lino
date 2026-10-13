import AppKit
import WebKit

@MainActor
final class PrintSurface: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var loaded: CheckedContinuation<Void, Error>?
    private var printed: CheckedContinuation<Bool, Never>?
    private var timeout: Task<Void, Never>?
    override init() {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init(); webView.navigationDelegate = self
    }
    func load(_ html: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            loaded = continuation
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                self?.finishLoad(NSError(domain: "Lino", code: 1, userInfo: [NSLocalizedDescriptionKey: localized("export.loadTimeout")]))
            }
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
    private func finishLoad(_ error: Error? = nil) {
        timeout?.cancel(); timeout = nil
        guard let continuation = loaded else { return }; loaded = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
    func print(in window: NSWindow, info: NSPrintInfo, pdf: URL?) async -> Bool {
        let copy = info.copy() as! NSPrintInfo
        if let pdf { copy.jobDisposition = .save; copy.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = pdf }
        let operation = webView.printOperation(with: copy)
        operation.showsPrintPanel = pdf == nil; operation.showsProgressPanel = true
        return await withCheckedContinuation { continuation in
            printed = continuation
            operation.runModal(for: window, delegate: self, didRun: #selector(didPrint(_:success:context:)), contextInfo: nil)
        }
    }
    @objc private func didPrint(_ operation: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?) {
        let continuation = printed; printed = nil; continuation?.resume(returning: success)
    }
    func cancel() {
        webView.stopLoading(); finishLoad(CancellationError())
    }
}
