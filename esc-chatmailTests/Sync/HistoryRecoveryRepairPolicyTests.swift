import XCTest
@testable import esc_chatmail

/// `HistoryRecoveryRepairPolicy`: which stored rows a history-recovery repair asks Gmail
/// about, what Gmail's answer does to them, and where the next batch starts.
final class HistoryRecoveryRepairPolicyTests: XCTestCase {
    private typealias Row = HistoryRecoveryRepairPolicy.StoredRow

    private static func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: 800_000_000 + seconds)
    }

    func testCandidates_areTheRowsTheListingsContradict() {
        let rows = [
            Row(messageId: "same", internalDate: Self.at(5), hasInbox: true, isUnread: true),
            Row(messageId: "gone", internalDate: Self.at(4), hasInbox: false, isUnread: false),
            Row(messageId: "archived", internalDate: Self.at(3), hasInbox: true, isUnread: false),
            Row(messageId: "read", internalDate: Self.at(2), hasInbox: false, isUnread: true),
            Row(messageId: "unarchived", internalDate: Self.at(1), hasInbox: false, isUnread: false)
        ]

        let candidates = HistoryRecoveryRepairPolicy.candidates(
            stored: rows,
            listed: ["same", "archived", "read", "unarchived"],
            inInbox: ["same", "unarchived"],
            unread: ["same"]
        )

        XCTAssertEqual(candidates.map(\.messageId), ["gone", "archived", "read", "unarchived"])
    }

    func testVerdict_trashSpamOrDraft_removes_elseTakesGmailsInboxAndUnread() {
        XCTAssertEqual(HistoryRecoveryRepairPolicy.verdict(forLabelIds: ["TRASH"]), .remove)
        XCTAssertEqual(HistoryRecoveryRepairPolicy.verdict(forLabelIds: ["SPAM", "INBOX"]), .remove)
        XCTAssertEqual(HistoryRecoveryRepairPolicy.verdict(forLabelIds: ["DRAFT"]), .remove)
        XCTAssertEqual(
            HistoryRecoveryRepairPolicy.verdict(forLabelIds: ["INBOX", "UNREAD", "IMPORTANT"]),
            .keep(hasInbox: true, isUnread: true)
        )
        XCTAssertEqual(HistoryRecoveryRepairPolicy.verdict(forLabelIds: nil), .keep(hasInbox: false, isUnread: false))
    }

    /// Every candidate answered: the next batch starts at this one's oldest row.
    func testNextUpperBound_everyCandidateAnswered_isTheLowerBound() {
        let candidates = [Row(messageId: "a", internalDate: Self.at(50), hasInbox: true, isUnread: false)]

        XCTAssertEqual(
            HistoryRecoveryRepairPolicy.nextUpperBound(
                lowerBound: Self.at(10),
                upperBound: Self.at(100),
                candidatesNewestFirst: candidates,
                answered: ["a"]
            ),
            Self.at(10)
        )
    }

    /// A row left unanswered (budget or a failure) stays owed with everything older; the
    /// rows newer than it are done, so the repair still moves.
    ///
    /// Revert-check: return `lowerBound` unconditionally from
    /// `HistoryRecoveryRepairPolicy.nextUpperBound`.
    func testNextUpperBound_unansweredRow_staysOwedWithEverythingOlder() {
        let candidates = [
            Row(messageId: "newest", internalDate: Self.at(90), hasInbox: true, isUnread: false),
            Row(messageId: "failed", internalDate: Self.at(60), hasInbox: true, isUnread: false),
            Row(messageId: "older", internalDate: Self.at(30), hasInbox: true, isUnread: false)
        ]

        let next = HistoryRecoveryRepairPolicy.nextUpperBound(
            lowerBound: Self.at(10),
            upperBound: Self.at(100),
            candidatesNewestFirst: candidates,
            answered: ["newest", "older"]
        )

        XCTAssertEqual(next.timeIntervalSince(Self.at(60)), 0.001, accuracy: 0.0001)
    }

    func testQuery_widensTheSpanByASecondAtEachEnd() {
        XCTAssertEqual(
            HistoryRecoveryRepairPolicy.query(
                "in:inbox",
                from: Date(timeIntervalSince1970: 1000.4),
                before: Date(timeIntervalSince1970: 2000.2)
            ),
            "in:inbox after:999 before:2002"
        )
    }

    /// A row `apply` left alone because an action was queued meanwhile keeps the bound
    /// above it; never above the bound the repair was owed at.
    ///
    /// Revert-check: return `planned` unconditionally from
    /// `HistoryRecoveryRepairPolicy.progressAfterApply`.
    func testProgressAfterApply_skippedRow_keepsTheBoundAboveIt() {
        XCTAssertEqual(
            HistoryRecoveryRepairPolicy.progressAfterApply(
                planned: .advances(to: Self.at(10)),
                owedUpperBound: Self.at(100),
                skippedDates: [Self.at(40), Self.at(70)]
            ),
            .advances(to: Self.at(70).addingTimeInterval(0.001))
        )
        XCTAssertEqual(
            HistoryRecoveryRepairPolicy.progressAfterApply(
                planned: .advances(to: Self.at(10)),
                owedUpperBound: Self.at(100),
                skippedDates: []
            ),
            .advances(to: Self.at(10))
        )
        XCTAssertEqual(
            HistoryRecoveryRepairPolicy.progressAfterApply(
                planned: .advances(to: Self.at(10)),
                owedUpperBound: Self.at(100),
                skippedDates: [Self.at(100)]
            ),
            .advances(to: Self.at(100))
        )
    }

    /// Runs that leave the bound in place are counted; after the limit the bound steps to
    /// the escape bound, and any progress resets the count.
    ///
    /// Revert-check: return `(progress, runs)` unconditionally from the no-progress case
    /// of `HistoryRecoveryRepairPolicy.progressAfterStall`.
    func testProgressAfterStall_stepsPastWhatHoldsTheBoundAfterTheLimit() {
        let owed = Self.at(100)
        let limit = HistoryRecoveryRepairPolicy.maximumRunsWithoutProgress

        let early = HistoryRecoveryRepairPolicy.progressAfterStall(
            .advances(to: owed),
            owedUpperBound: owed,
            runsWithoutProgressBefore: limit - 2,
            escapeBound: Self.at(80)
        )
        XCTAssertEqual(early.progress, .advances(to: owed))
        XCTAssertEqual(early.runsWithoutProgress, limit - 1)

        let stepped = HistoryRecoveryRepairPolicy.progressAfterStall(
            .holds,
            owedUpperBound: owed,
            runsWithoutProgressBefore: limit - 1,
            escapeBound: Self.at(80)
        )
        XCTAssertEqual(stepped.progress, .advances(to: Self.at(80)))
        XCTAssertEqual(stepped.runsWithoutProgress, 0)

        let moved = HistoryRecoveryRepairPolicy.progressAfterStall(
            .advances(to: Self.at(50)),
            owedUpperBound: owed,
            runsWithoutProgressBefore: limit - 1,
            escapeBound: nil
        )
        XCTAssertEqual(moved.progress, .advances(to: Self.at(50)))
        XCTAssertEqual(moved.runsWithoutProgress, 0)
    }
}
