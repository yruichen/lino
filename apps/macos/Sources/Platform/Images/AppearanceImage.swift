import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// Native bookmarks retain the identity of a user-selected backdrop without
/// copying personal images into application output or document asset folders.
@MainActor
enum AppearanceImage {
    private static var bookmark: String?
    private(set) static var data: Data?
    private(set) static var image: NSImage?
    private(set) static var name = ""
    private(set) static var mime = "image/png"
    private(set) static var failure: String?
    static func select(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bytes = try read(url)
        try ImageData.validate(bytes, mime: "image/raster")
        bookmark = nil
        let token = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil).base64EncodedString()
        return UUID().uuidString + ":" + token
    }
    static func refresh(_ value: String) {
        guard bookmark != value else { return }
        bookmark = value; data = nil; image = nil; name = ""; failure = nil
        guard !value.isEmpty else { return }
        do {
            let (bytes, kind, picture, url) = try snapshot(value)
            data = bytes; image = picture; name = url.lastPathComponent
            mime = UTType(kind as String)?.preferredMIMEType ?? "image/png"
        } catch { failure = localized("settings.backgroundUnavailable") }
    }
    static func snapshot(_ value: String) throws -> (Data, String, NSImage, URL) {
        let parts = value.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil, let token = Data(base64Encoded: String(parts[1])) else { throw ImageDataError.invalid }
        var stale = false
        let url = try URL(resolvingBookmarkData: token, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bytes = try read(url)
        try ImageData.validate(bytes, mime: "image/raster")
        guard let picture = NSImage(data: bytes), let source = CGImageSourceCreateWithData(bytes as CFData, nil), let kind = CGImageSourceGetType(source) else { throw ImageDataError.invalid }
        return (bytes, kind as String, picture, url)
    }
    private static func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = 16 * 1024 * 1024
        var data = Data()
        while data.count <= limit {
            let part = try handle.read(upToCount: limit + 1 - data.count) ?? Data()
            if part.isEmpty { break }
            data.append(part)
        }
        return data
    }
}

@MainActor
final class AppearanceResources: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "local", url.path == "/background",
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "asset" })?.value == ThemePalette.preferences?.background_image,
              let data = AppearanceImage.data else {
            urlSchemeTask.didFailWithError(resourceError(localized("settings.backgroundUnavailable"))); return
        }
        let response = URLResponse(url: url, mimeType: AppearanceImage.mime, expectedContentLength: data.count, textEncodingName: nil)
        urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
