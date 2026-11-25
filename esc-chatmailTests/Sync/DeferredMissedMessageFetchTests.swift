import XCTest
@testable import esc_chatmail

/// The missed-message IDs an app refresh lists and leaves for a sync with a
/// larger budget to fetch (scalability review step 8).
final class DeferredMissedMessageFetchTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "DeferredMissedMessageFetchTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// Deferring adds without duplicates; settling forgets the IDs a run
    /// attempted and resolved, and the key goes once nothing is left.
    @MainActor
    func testDeferAndSettle_forgetOnlyTheResolvedIds() {
        let reconciliation = makeReconciliation()

        reconciliation.deferMissedMessageFetches(["a", "b"])
        reconciliation.deferMissedMessageFetches(["b", "c"])
        XCTAssertEqual(stored(), ["a", "b", "c"])

        reconciliation.settleMissedMessageFetches(attemptedDeferredIds: ["a", "c"], failedIds: [])
        XCTAssertEqual(stored(), ["b"])

        reconciliation.settleMissedMessageFetches(attemptedDeferredIds: ["b"], failedIds: [])
        XCTAssertNil(defaults.object(forKey: SyncConfig.deferredMissedMessageIdsKey))
    }

    /// An ID whose fetch failed is kept for the next sync, with the failure
    /// counted, whether an app refresh deferred it or the run's own check
    /// found it: no later check lists it, because each lists after the last
    /// sync less five minutes, and the last sync is now the one that failed.
    ///
    /// Revert-check: forget every attempted ID in
    /// `SyncReconciliation.settleMissedMessageFetches` (drop the
    /// `keepFailure(entry)` branch for a stored entry) and "b" is gone.
    /// Revert-check: drop the loop that keeps the run's own `failedIds` and
    /// "own" is not kept.
    @MainActor
    func testSettle_keepsTheIdsThatFailedWithTheirAttemptsCounted() {
        let reconciliation = makeReconciliation()
        reconciliation.deferMissedMessageFetches(["a", "b"])

        reconciliation.settleMissedMessageFetches(attemptedDeferredIds: ["a", "b"], failedIds: ["b", "own"])

        XCTAssertEqual(reconciliation.storedDeferredMissedMessages().map(\.id), ["b", "own"])
        XCTAssertEqual(reconciliation.storedDeferredMissedMessages().map(\.failedAttempts), [1, 1])

        reconciliation.deferMissedMessageFetches(["b"])
        XCTAssertEqual(
            reconciliation.storedDeferredMissedMessages().first { $0.id == "b" }?.failedAttempts, 1,
            "Deferred again by an app refresh, it keeps its count"
        )
    }

    /// An ID that never fetches is dropped after its last allowed attempt,
    /// not fetched by every sync without end.
    ///
    /// Revert-check: never drop in `SyncReconciliation.settleMissedMessageFetches`
    /// (keep the entry whatever its `failedAttempts`) and "x" is still kept.
    @MainActor
    func testSettle_dropsAnIdThatFailedEveryAllowedAttempt() {
        let reconciliation = makeReconciliation()
        reconciliation.deferMissedMessageFetches(["x"])
        var now = Date()

        for attempt in 1..<SyncConfig.maxDeferredMissedMessageFetchAttempts {
            reconciliation.settleMissedMessageFetches(attemptedDeferredIds: ["x"], failedIds: ["x"], now: now)
            XCTAssertEqual(stored(), ["x"], "Kept after failed attempt \(attempt)")
            now += SyncConfig.deferredMissedMessageFailureSpacing
        }
        reconciliation.settleMissedMessageFetches(attemptedDeferredIds: ["x"], failedIds: ["x"], now: now)

        XCTAssertNil(stored(), "Dropped after its last allowed attempt")
    }

    /// Failures closer together than the spacing count once: a foreground
    /// sync runs every minute, and an ID dropped after five minutes of 5xx
    /// would never be listed again. It is kept, and still fetched each sync.
    ///
    /// Revert-check: count every failure in
    /// `SyncReconciliation.settleMissedMessageFetches` (drop the
    /// `deferredMissedMessageFailureSpacing` check) and "x" is dropped.
    @MainActor
    func testSettle_failuresInsideTheSpacingCountOnce() {
        let reconciliation = makeReconciliation()
        reconciliation.deferMissedMessageFetches(["x"])
        let start = Date()

        for minute in 0..<(2 * SyncConfig.maxDeferredMissedMessageFetchAttempts) {
            reconciliation.settleMissedMessageFetches(
                attemptedDeferredIds: ["x"],
                failedIds: ["x"],
                now: start.addingTimeInterval(TimeInterval(minute) * 60)
            )
        }

        XCTAssertEqual(stored(), ["x"])
        XCTAssertEqual(reconciliation.storedDeferredMissedMessages().first?.failedAttempts, 1)
    }

    /// The list is bounded, and the newest IDs are the ones kept.
    ///
    /// Revert-check: drop the `prefix(SyncConfig.maxDeferredMissedMessageIds)`
    /// in `SyncReconciliation.deferMissedMessageFetches` and all are kept.
    @MainActor
    func testDefer_keepsTheNewestUpToTheCap() {
        let reconciliation = makeReconciliation()
        let cap = SyncConfig.maxDeferredMissedMessageIds
        let ids = (0...cap).map { "id-\($0)" }

        reconciliation.deferMissedMessageFetches(ids)

        XCTAssertEqual(stored()?.count, cap)
        XCTAssertEqual(stored()?.first, "id-1")
        XCTAssertEqual(stored()?.last, "id-\(cap)")
    }

    /// A sign-out removes the list with the rest of the account's sync state.
    func testClearAccountScopedSyncDefaults_removesTheDeferredList() throws {
        let source = try repositorySource("esc-chatmail/Services/Security/AuthSession.swift")
        let body = try XCTUnwrap(source.range(of: "private func clearAccountScopedSyncDefaults()"))
        let tail = source[body.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "\n    }\n"))
        XCTAssertTrue(tail[..<end.lowerBound].contains("SyncConfig.deferredMissedMessageIdsKey"))
    }

    @MainActor
    private func makeReconciliation() -> SyncReconciliation {
        let fetcher = MessageFetcher(apiClient: MockGmailAPIClient(), clock: FakeSyncClock())
        return SyncReconciliation(messageFetcher: fetcher, defaults: defaults)
    }

    /// The IDs kept, oldest first; nil when the key is gone.
    private func stored() -> [String]? {
        guard let data = defaults.data(forKey: SyncConfig.deferredMissedMessageIdsKey) else { return nil }
        return try? JSONDecoder()
            .decode([SyncReconciliation.DeferredMissedMessage].self, from: data)
            .map(\.id)
    }
}
