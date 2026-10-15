import Foundation

enum ReleaseFetchError: Error, Sendable {
    case rateLimited, invalidResponse, tooLarge, http(Int)
}

/// Only public release metadata leaves this adapter. No credentials or document data.
struct GitHubReleaseClient: Sendable {
    func fetch(version: String) async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/yruichen/lino/releases?per_page=100")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Lino/" + version, forHTTPHeaderField: "User-Agent")
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ReleaseFetchError.invalidResponse }
        if response.statusCode == 429 || response.statusCode == 403 && (response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" || response.value(forHTTPHeaderField: "Retry-After") != nil) { throw ReleaseFetchError.rateLimited }
        guard response.statusCode == 200 else { throw ReleaseFetchError.http(response.statusCode) }
        let limit = 2 * 1024 * 1024
        guard response.expectedContentLength <= limit else { throw ReleaseFetchError.tooLarge }
        var bytes = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard bytes.count < limit else { throw ReleaseFetchError.tooLarge }
            bytes.append(byte)
        }
        guard let json = String(data: bytes, encoding: .utf8) else { throw ReleaseFetchError.invalidResponse }
        return json
    }
}
