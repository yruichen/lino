import Foundation

// UniFFI owns the ABI and Sendable conformance. Each call uses the shared Rust
// runtime; filesystem work runs off the main thread and never serializes edits
// behind a Swift actor waiting for save I/O.
final class DocumentBackend: Sendable {
    private let service = DocumentService()
    func perform<T: Sendable>(_ action: @escaping @Sendable (DocumentService) throws -> T) async throws -> T {
        let service = self.service
        do { return try await Task.detached(priority: .userInitiated) { try action(service) }.value }
        catch BridgeError.Failed(let message) { throw NSError(domain: "OpenTypora", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
