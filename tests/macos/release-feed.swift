import Foundation

@main
struct ReleaseFeedChecks {
    static func main() async throws {
        let url = URL(string: "https://yruichen.github.io/lino/updates/releases.json")!
        let client = ReleaseFeedClient { request in
            precondition(request.url == url)
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
            precondition(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == nil)
            precondition(request.value(forHTTPHeaderField: "Accept") == "application/json")
            return (Data("[]".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let result = try await client.fetch(version: "0.0.4"); precondition(result == "[]")
        for code in [403, 404, 429, 503] {
            do {
                _ = try await ReleaseFeedClient { _ in (Data(), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!) }.fetch(version: "0.0.4")
                preconditionFailure("HTTP error must remain visible")
            } catch ReleaseFetchError.rateLimited { precondition(code == 429) }
            catch ReleaseFetchError.http(let status) { precondition(status == code) }
        }
        for data in [Data("<html>not a release feed</html>".utf8), Data("{}".utf8), Data([0xff])] {
            do {
                _ = try await ReleaseFeedClient { _ in (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!) }.fetch(version: "0.0.4")
                preconditionFailure("Invalid release feed must not report up to date")
            } catch ReleaseFetchError.invalidResponse {}
        }
        do {
            _ = try await ReleaseFeedClient { _ in (Data(repeating: 32, count: 2 * 1024 * 1024 + 1), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!) }.fetch(version: "0.0.4")
            preconditionFailure("Response limit must be enforced")
        } catch ReleaseFetchError.tooLarge {}
        print("Release feed: anonymous Pages request, HTTP failures, invalid content and response size passed.")
    }
}
