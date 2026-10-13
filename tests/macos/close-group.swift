import Foundation

@MainActor
final class DocumentFixture: DocumentCloseParticipant {
    var closed = false
    var prepareSucceeds = true
    var commitSucceeds = true
    var prepared = false
    var cancelCount = 0
    func prepareClose() async -> Bool { prepared = prepareSucceeds; return prepared }
    func commitClose() async -> Bool { guard prepared, commitSucceeds else { return false }; closed = true; return true }
    func cancelClose() async { prepared = false; cancelCount += 1 }
}
@main struct Checks {
    @MainActor static func main() async {
        let first = DocumentFixture(), cancelled = DocumentFixture(), unrelated = DocumentFixture()
        cancelled.prepareSucceeds = false
        let rejected = await closeDocumentGroup([first, cancelled, unrelated])
        precondition(!rejected && !first.closed && !first.prepared)
        precondition(first.cancelCount == 1 && cancelled.cancelCount == 0 && unrelated.cancelCount == 0)
        let boundLater = DocumentFixture()
        let snapshotRejected = await closeDocumentGroup([boundLater], beforeCommit: { false })
        precondition(!snapshotRejected && !boundLater.closed && boundLater.cancelCount == 1)
        let one = DocumentFixture(), two = DocumentFixture()
        let accepted = await closeDocumentGroup([one, two])
        precondition(accepted && one.closed && two.closed)
        let committed = DocumentFixture(), failed = DocumentFixture(), remaining = DocumentFixture()
        failed.commitSucceeds = false
        let failedCommit = await closeDocumentGroup([committed, failed, remaining])
        precondition(!failedCommit && committed.closed && !failed.closed && !remaining.closed)
        precondition(failed.cancelCount == 1 && remaining.cancelCount == 1)
        print("Close group: cancel, post-save snapshot and commit failure checks passed.")
    }
}
