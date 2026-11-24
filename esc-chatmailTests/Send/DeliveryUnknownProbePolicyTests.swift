import XCTest
@testable import esc_chatmail

/// The pure half of the "Delivery unknown" lookup: which records are asked
/// about, the search, and what an answer means. A wrong "not found" offers
/// Edit and resend for a message Gmail may have, which is a duplicate send.
final class DeliveryUnknownProbePolicyTests: XCTestCase {
    private typealias Policy = DeliveryUnknownProbePolicy
    private let runStart = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidate(
        id: String = "optimistic-1",
        marker: String? = OutboundSendRemoteState.ambiguousMessageID,
        threadID: String? = nil,
        admittedAgo: TimeInterval? = 2 * 60 * 60,
        probedAgo: TimeInterval? = nil
    ) -> Policy.Candidate {
        Policy.Candidate(
            optimisticMessageID: id,
            remoteCommittedMessageId: marker,
            remoteCommittedThreadId: threadID,
            admittedAt: admittedAgo.map { runStart.addingTimeInterval(-$0) },
            deliveryProbedAt: probedAgo.map { runStart.addingTimeInterval(-$0) }
        )
    }

    // Revert-check: fails if `DeliveryUnknownProbePolicy.isEligible` stops
    // requiring the ambiguous marker, `admittedAt` or the quiet period.
    func testIsEligible_onlyAnAmbiguousRecordAdmittedAnHourBeforeTheRun() {
        XCTAssertTrue(Policy.isEligible(candidate(), runStartedAt: runStart))
        XCTAssertTrue(Policy.isEligible(candidate(admittedAgo: Policy.quietPeriod), runStartedAt: runStart))

        XCTAssertFalse(
            Policy.isEligible(candidate(marker: OutboundSendRemoteState.inFlightMessageID), runStartedAt: runStart),
            "An in-flight record is a live send until cold recovery converts it"
        )
        XCTAssertFalse(Policy.isEligible(candidate(marker: OutboundSendRemoteState.notSentMessageID), runStartedAt: runStart))
        XCTAssertFalse(Policy.isEligible(candidate(marker: nil), runStartedAt: runStart))
        XCTAssertFalse(Policy.isEligible(candidate(marker: "gmail-id", threadID: "thread"), runStartedAt: runStart))
        XCTAssertFalse(
            Policy.isEligible(candidate(threadID: "thread"), runStartedAt: runStart),
            "A thread ID means a committed send, whatever the message field holds"
        )
        XCTAssertFalse(
            Policy.isEligible(candidate(admittedAgo: nil), runStartedAt: runStart),
            "Admitted before model 7: its MIME may carry another Message-ID"
        )
        XCTAssertFalse(Policy.isEligible(candidate(admittedAgo: Policy.quietPeriod - 1), runStartedAt: runStart))
        XCTAssertFalse(
            Policy.isEligible(candidate(admittedAgo: -60), runStartedAt: runStart),
            "An admission after the run started is not past its quiet period"
        )
    }

    func testIsEligible_aFoundRecordWaitsTheReprobeInterval() {
        XCTAssertFalse(Policy.isEligible(candidate(probedAgo: Policy.reprobeInterval - 1), runStartedAt: runStart))
        XCTAssertTrue(Policy.isEligible(candidate(probedAgo: Policy.reprobeInterval), runStartedAt: runStart))
    }

    func testCandidatesToProbe_oldestAdmissionFirstAndCapped() {
        let candidates = [
            candidate(id: "c", admittedAgo: 3 * 60 * 60),
            candidate(id: "recent", admittedAgo: 60),
            candidate(id: "a", admittedAgo: 9 * 60 * 60),
            candidate(id: "d", admittedAgo: 2 * 60 * 60),
            candidate(id: "b", admittedAgo: 5 * 60 * 60)
        ]

        let probed = Policy.candidatesToProbe(candidates, runStartedAt: runStart).map(\.optimisticMessageID)

        XCTAssertEqual(probed, ["a", "b", "c"])
        XCTAssertEqual(probed.count, Policy.maximumProbesPerRun)
    }

    func testAllowsProbing_onlyAnExpensiveRunWithACompleteCleanHistorySlice() {
        XCTAssertTrue(Policy.allowsProbing(allowsExpensiveWork: true, historySliceIsTerminal: true, hadFetchFailures: false))
        XCTAssertFalse(
            Policy.allowsProbing(allowsExpensiveWork: false, historySliceIsTerminal: true, hadFetchFailures: false),
            "Never in an app refresh"
        )
        XCTAssertFalse(
            Policy.allowsProbing(allowsExpensiveWork: true, historySliceIsTerminal: false, hadFetchFailures: false),
            "History not caught up is not a witness"
        )
        XCTAssertFalse(
            Policy.allowsProbing(allowsExpensiveWork: true, historySliceIsTerminal: true, hadFetchFailures: true),
            "A failed fetch could be the echo"
        )
    }

    func testQuery_searchesTheSendsOwnMessageIDEverywhere() {
        let messageID = MimeBuilder.messageId(forOptimisticMessageID: "optimistic-1")
        let bare = String(messageID.dropFirst().dropLast())

        XCTAssertEqual(Policy.query(forOptimisticMessageID: "optimistic-1"), "rfc822msgid:\(bare) in:anywhere")
        XCTAssertFalse(bare.contains("<") || bare.contains(">"))
    }

    // Revert-check: fails if `DeliveryUnknownProbePolicy.verdict` reads an
    // empty page that has a next page token as "not found".
    func testVerdict_onlyAnEmptyFinalAnswerIsNotFound() {
        XCTAssertEqual(Policy.verdict(for: .listed(messageIDs: [], nextPageToken: nil)), .notFound)
        XCTAssertEqual(Policy.verdict(for: .listed(messageIDs: [], nextPageToken: "more")), .none)
        XCTAssertEqual(Policy.verdict(for: .listed(messageIDs: ["m1"], nextPageToken: nil)), .found(["m1"]))
        XCTAssertEqual(Policy.verdict(for: .listed(messageIDs: ["m1"], nextPageToken: "more")), .found(["m1"]))
        XCTAssertEqual(Policy.verdict(for: .failed), .none)
    }
}
