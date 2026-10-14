import Foundation
import WebKit

@MainActor
final class ImageResources: NSObject, WKURLSchemeHandler {
    private let backend: DocumentBackend
    private let session: () -> String?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var activeRequests = 0
    init(backend: DocumentBackend, session: @escaping () -> String?) { self.backend = backend; self.session = session }
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        guard activeRequests < 8, let id = session(), let url = urlSchemeTask.request.url,
              url.host == "local", url.path == "/image",
              let source = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "source" })?.value,
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "session" })?.value == id,
              source.utf8.count <= 8192 else {
            urlSchemeTask.didFailWithError(resourceError(localized("media.invalidResource"))); return
        }
        activeRequests += 1
        tasks[key] = Task { [weak self] in
            guard let self else { return }
            defer { activeRequests -= 1; tasks.removeValue(forKey: key) }
            do {
                let fileRef = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "file" })?.value.flatMap { $0.isEmpty ? nil : $0 }
                let image = try await backend.perform { try $0.readImage(sessionId: id, fileRef: fileRef, source: source) }
                guard !Task.isCancelled, tasks[key] != nil else { return }
                guard session() == id else { throw resourceError(localized("media.oldResource")) }
                let data = Data(image.bytes)
                do { try await Task.detached { try ImageData.validate(data, mime: image.mime) }.value }
                catch { throw resourceError(localized("media.imageLimit")) }
                guard !Task.isCancelled, tasks[key] != nil else { return }
                let response = URLResponse(url: url, mimeType: image.mime, expectedContentLength: data.count, textEncodingName: nil)
                urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
            } catch {
                guard !Task.isCancelled, tasks[key] != nil else { return }
                urlSchemeTask.didFailWithError(error)
            }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) { tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel() }
    func cancelAll() { for task in tasks.values { task.cancel() }; tasks.removeAll() }
}
func resourceError(_ message: String) -> NSError { NSError(domain: "Lino.Resources", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
