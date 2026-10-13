import AppKit
import WebKit

@MainActor
final class EditorBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let backend = DocumentBackend()
    weak var webView: WKWebView?
    private(set) var generation = 0
    var onStatus: (([String: Any]) -> Void)?
    var onDocument: (([String: Any]) -> Void)?
    var onReady: (() -> Void)?
    var onError: ((String) -> Void)?
    var onTerminated: (() -> Void)?

    func beginNavigation() {
        generation += 1
        guard let content = webView?.configuration.userContentController else { return }
        content.removeAllUserScripts()
        content.addUserScript(WKUserScript(source: "window.__openTyporaViewGeneration = \(generation); window.__openTyporaLocale = '\(LanguagePreferences.shared.locale)';", injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              body["viewGeneration"] as? Int == generation,
              let kind = body["kind"] as? String else { return }
        switch kind {
        case "rpc":
            guard let json = body["json"] as? String else { return }
            let requestGeneration = generation
            Task { [weak self] in
                guard let self else { return }
                do {
                    let response = try await backend.perform { try $0.request(requestJson: json) }
                    guard requestGeneration == generation else { return }
                    _ = try await call("receive", arguments: [response])
                } catch {
                    guard requestGeneration == generation else { return }
                    let id = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
                    _ = try? await call("transportError", arguments: [id?["request_id"] as? String ?? "", error.localizedDescription])
                }
            }
        case "document": onDocument?(body)
        case "ready": onReady?()
        case "status":
            if let status = body["status"] as? [String: Any] { onStatus?(status) }
        case "error": onError?(body["message"] as? String ?? localized("error.editor"))
        default: break
        }
    }

    func call(_ name: String, arguments: [Any] = []) async throws -> Any {
        guard let webView else { throw bridgeError(localized("error.viewClosed")) }
        let requestedGeneration = generation
        let result = try await webView.callAsyncJavaScript("return await window.openTypora[name](...values)", arguments: ["name": name, "values": arguments], in: nil, contentWorld: .page)
        guard requestedGeneration == generation else { throw bridgeError(localized("error.oldResult")) }
        return result ?? NSNull()
    }

    func command(_ name: String, completion: ((Bool) -> Void)? = nil) {
        let requestedGeneration = generation
        webView?.callAsyncJavaScript("return window.openTypora.command(name)", arguments: ["name": name], in: nil, in: .page) { [weak self] result in
            guard let self, requestedGeneration == generation else { completion?(false); return }
            switch result {
            case .success(let value): completion?(value as? Bool == true)
            case .failure(let error): onError?(error.localizedDescription); completion?(false)
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let root = Bundle.main.resourceURL?.appendingPathComponent("Editor", isDirectory: true).standardizedFileURL.path
        let permitted = url?.isFileURL == true && root.map { url!.standardizedFileURL.path.hasPrefix($0 + "/") } == true
        decisionHandler(permitted ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onError?(error.localizedDescription) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onError?(error.localizedDescription) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onTerminated?() }
    private func bridgeError(_ message: String) -> NSError {
        NSError(domain: "OpenTypora", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
