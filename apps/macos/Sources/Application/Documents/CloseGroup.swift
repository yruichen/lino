import Foundation

@MainActor
protocol DocumentCloseParticipant: AnyObject {
    var closed: Bool { get }
    func prepareClose() async -> Bool
    func commitClose() async -> Bool
    func cancelClose() async
}

/// Confirm all participants before destroying any input owner. Cancellation
/// only touches participants prepared by this group, never unrelated saves.
@MainActor
func closeDocumentGroup(_ documents: [any DocumentCloseParticipant], beforeCommit: () async -> Bool = { true }) async -> Bool {
    var prepared: [any DocumentCloseParticipant] = []
    for document in documents where !document.closed {
        guard await document.prepareClose() else {
            for previous in prepared { await previous.cancelClose() }
            return false
        }
        prepared.append(document)
    }
    guard await beforeCommit() else {
        for document in prepared { await document.cancelClose() }
        return false
    }
    for document in prepared {
        guard await document.commitClose() else {
            for remaining in prepared where !remaining.closed { await remaining.cancelClose() }
            return false
        }
    }
    return true
}
