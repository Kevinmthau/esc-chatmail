import XCTest
@testable import esc_chatmail

/// When a failing run spends one of the escape hatch's strikes
/// (`SyncFailureStrikePolicy`; architecture review 2026-11, sync-engine#2).
/// The runs these decide are driven end to end in `IncrementalSyncCursorTests`.
final class SyncFailureStrikePolicyTests: XCTestCase {
    private let lastStrike = Date(timeIntervalSince1970: 1_700_000_000)
    private let spacing = SyncFailureStrikePolicy.Spacing.atLeast(300)

    // Revert-check: `return elapsed >= minimum` in `countsAsStrike` set to
    // `return true` fails the first assertion; set to `elapsed > minimum`
    // fails the second.
    func testCountsAsStrike_onTheSlicePath_onlyOnceTheSpacingHasPassed() {
        XCTAssertFalse(SyncFailureStrikePolicy.countsAsStrike(
            lastStrikeAt: lastStrike, now: lastStrike.addingTimeInterval(299), spacing: spacing
        ))
        XCTAssertTrue(SyncFailureStrikePolicy.countsAsStrike(
            lastStrikeAt: lastStrike, now: lastStrike.addingTimeInterval(300), spacing: spacing
        ))
    }

    // Revert-check: `guard let lastStrikeAt else { return true }` returning false.
    func testCountsAsStrike_withNoKnownLastStrike_counts() {
        XCTAssertTrue(SyncFailureStrikePolicy.countsAsStrike(
            lastStrikeAt: nil, now: lastStrike, spacing: spacing
        ))
    }

    // Revert-check: the `elapsed >= 0` term in `countsAsStrike`.
    func testCountsAsStrike_withTheClockBehindTheLastStrike_counts() {
        XCTAssertTrue(SyncFailureStrikePolicy.countsAsStrike(
            lastStrikeAt: lastStrike, now: lastStrike.addingTimeInterval(-1), spacing: spacing
        ))
    }

    // Revert-check: `case .everyFailingRun: return true` set to `return false`.
    func testCountsAsStrike_everyFailingRun_countsAtOnce() {
        XCTAssertTrue(SyncFailureStrikePolicy.countsAsStrike(
            lastStrikeAt: lastStrike, now: lastStrike, spacing: .everyFailingRun
        ))
    }

    func testSliceSpacing_isTheConfiguredMinimum() {
        XCTAssertEqual(
            SyncFailureStrikePolicy.slice,
            .atLeast(SyncConfig.minimumSyncFailureStrikeSpacing)
        )
        XCTAssertGreaterThan(SyncConfig.minimumSyncFailureStrikeSpacing, 0)
    }

    // Revert-check: the `guard countsAsStrike(…) else { return prior }` in
    // `proposed(after:now:spacing:)` removed fails the first assertion; the
    // stamp `lastStrikeAt: now` set to `prior.lastStrikeAt` fails the second.
    func testProposed_stampsAStrikeOnlyWhenOneCounts() {
        let prior = SyncFailureStrikes(count: 1, lastStrikeAt: lastStrike)
        let soon = lastStrike.addingTimeInterval(10)
        let later = lastStrike.addingTimeInterval(600)

        XCTAssertEqual(SyncFailureStrikePolicy.proposed(after: prior, now: soon, spacing: spacing), prior)
        XCTAssertEqual(
            SyncFailureStrikePolicy.proposed(after: prior, now: later, spacing: spacing),
            SyncFailureStrikes(count: 2, lastStrikeAt: later)
        )
    }

    /// A count already at the threshold (a hatch that was armed but refused)
    /// stays there, counted or not, so the hatch can still fire.
    func testProposed_atTheThreshold_staysAtTheThreshold() {
        let threshold = SyncConfig.maxConsecutiveSyncFailures
        let prior = SyncFailureStrikes(count: threshold, lastStrikeAt: lastStrike)

        XCTAssertEqual(
            SyncFailureStrikePolicy.proposed(after: prior, now: lastStrike, spacing: spacing).count,
            threshold
        )
        XCTAssertEqual(
            SyncFailureStrikePolicy.proposed(
                after: prior, now: lastStrike.addingTimeInterval(600), spacing: spacing
            ).count,
            threshold
        )
    }

    // Revert-check: `if advanced { return .cleared }` removed fails the first
    // assertion; `hadFailures ? proposed : prior` set to `proposed` fails the third.
    func testStaged_clearsOnAdvance_keepsProposedOnAFailingHold_andPriorOnACleanHold() {
        let prior = SyncFailureStrikes(count: 1, lastStrikeAt: lastStrike)
        let proposed = SyncFailureStrikes(count: 2, lastStrikeAt: lastStrike.addingTimeInterval(600))

        XCTAssertEqual(
            SyncFailureStrikePolicy.staged(prior: prior, proposed: proposed, hadFailures: true, advanced: true),
            .cleared
        )
        XCTAssertEqual(
            SyncFailureStrikePolicy.staged(prior: prior, proposed: proposed, hadFailures: true, advanced: false),
            proposed
        )
        XCTAssertEqual(
            SyncFailureStrikePolicy.staged(prior: prior, proposed: .cleared, hadFailures: false, advanced: false),
            prior,
            "A run held with no failure (an unreadable ledger) keeps the strikes it found"
        )
    }
}
