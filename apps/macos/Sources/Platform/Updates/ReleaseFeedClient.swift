import Foundation

enum ReleaseFetchError: Error, Sendable {
    case rateLimited, invalidResponse, tooLarge, http(Int)
}

/// Public static metadata, published from Releases by CI. No API token or user account.
struct ReleaseFeedClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let transport: Transport
    init(transport: @escaping Transport = Self.load) { self.transport = transport }
    func fetch(version: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://yruichen.github.io/lino/updates/releases.json")!, cachePolicy: .reloadRevalidatingCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Lino/" + version, forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await transport(request)
        guard let response = response as? HTTPURLResponse else { throw ReleaseFetchError.invalidResponse }
        if response.statusCode == 429 { throw ReleaseFetchError.rateLimited }
        guard response.statusCode == 200 else { throw ReleaseFetchError.http(response.statusCode) }
        guard bytes.count <= 2 * 1024 * 1024 else { throw ReleaseFetchError.tooLarge }
        guard let json = String(data: bytes, encoding: .utf8), (try? JSONSerialization.jsonObject(with: bytes)) is [Any] else { throw ReleaseFetchError.invalidResponse }
        return json
    }
    private static func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { return (Data(), response) }
        let limit = 2 * 1024 * 1024
        guard response.expectedContentLength <= limit else { throw ReleaseFetchError.tooLarge }
        var bytes = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard bytes.count < limit else { throw ReleaseFetchError.tooLarge }
            bytes.append(byte)
        }
        return (bytes, response)
    }
}
