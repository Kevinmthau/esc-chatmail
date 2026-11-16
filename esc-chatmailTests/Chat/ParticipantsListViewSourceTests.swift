import XCTest
@testable import esc_chatmail

/// Pins, from the source text, that the sheet a mailing list's header opens draws its
/// senders as they are resolved (`ParticipantsListView.updateFromMessageSenders`).
///
/// A list with hundreds of senders opened a sheet that stayed empty until the last of them
/// had been asked of Contacts. `ParticipantLoader.resolveSenders` hands the senders over a
/// batch at a time now, and `ParticipantsListPolicy.sendersToDraw` says which rows to draw,
/// and both are run by tests of their own. But the sheet is what passes the one to the
/// other, and with that argument gone every one of those tests still passed and the sheet
/// was empty again.
///
/// HONEST SCOPE: this reads the view's text, because the rows are the view's private state
/// and a test host is told nothing of what a SwiftUI list draws. It cannot tell that a row
/// appears: `ParticipantLoaderTests` runs the hand-over and
/// `FullEmailEntryPointPresentationTests` the rule. Nothing has been seen in the app.
final class ParticipantsListViewSourceTests: XCTestCase {
    /// Revert-check: deleting the `onProgress:` argument from the `resolveSenders` call in
    /// `ParticipantsListView.updateFromMessageSenders` makes this fail, and so does
    /// assigning `sendersSoFar.map { Self.senderItem($0) }` there with no
    /// `ParticipantsListPolicy.sendersToDraw`, which cuts a list being resolved again back
    /// to its first batch.
    func testSendersSheet_sendersResolvedSoFar_areDrawnAsThePolicySays() throws {
        let load = try sendersLoad()
        let progress = try XCTUnwrap(
            load.firstIndex(of: "onProgress: { sendersSoFar in"),
            "The sheet no longer takes the senders resolved so far"
        )

        XCTAssertEqual(Array(load[(progress + 2)...].prefix(7)), [
            "cachedOtherParticipants = ParticipantsListPolicy.sendersToDraw(",
            "resolvedSoFar: sendersSoFar.map { Self.senderItem($0) },",
            "shown: cachedOtherParticipants,",
            "id: { $0.id },",
            "normalizedAddress: { EmailNormalizer.normalize($0.email) }",
            ")",
            "}"
        ])
    }

    /// A load that was cancelled (the sheet closed, or resolving again after a change in
    /// Contacts) still finishes the batch it is in and hands it over. The rows on screen
    /// are the next load's by then, so it draws nothing: not the batch, and not its result,
    /// which is short.
    ///
    /// Revert-check: deleting either `guard !Task.isCancelled else { return }` from
    /// `ParticipantsListView.updateFromMessageSenders` makes this fail: the one that opens
    /// the `onProgress` closure, or the one after the `resolveSenders` call.
    func testSendersSheet_cancelledLoad_drawsNeitherABatchNorItsResult() throws {
        let load = try sendersLoad()
        let progress = try XCTUnwrap(load.firstIndex(of: "onProgress: { sendersSoFar in"))
        let result = try XCTUnwrap(
            load.firstIndex(of: "cachedOtherParticipants = resolvedSenders.map { Self.senderItem($0) }"),
            "The sheet no longer draws the result of the load"
        )

        XCTAssertEqual(load[progress + 1], "guard !Task.isCancelled else { return }")
        XCTAssertEqual(load[result - 1], "guard !Task.isCancelled else { return }")
        XCTAssertGreaterThan(result, progress)
    }

    /// The lines of `updateFromMessageSenders`, trimmed, without its comment lines and its
    /// empty ones.
    private func sendersLoad() throws -> [String] {
        let code = try repositorySource("esc-chatmail/Views/Chat/ParticipantsListView.swift")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") }
        let function = try XCTUnwrap(
            code.firstIndex(of: "private func updateFromMessageSenders() async {"),
            "ParticipantsListView no longer has updateFromMessageSenders"
        )
        let nextFunction = try XCTUnwrap(code[(function + 1)...].firstIndex { $0.contains("func ") })
        return Array(code[(function + 1)..<nextFunction])
    }
}
