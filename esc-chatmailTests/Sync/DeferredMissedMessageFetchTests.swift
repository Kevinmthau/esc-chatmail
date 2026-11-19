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

    /// Deferring adds without duplicates; clearing forgets only the IDs a
    /// run attempted, and the key goes once nothing is left.
    @MainActor
    func testDeferAndClear_keepOnlyTheIdsNotYetAttempted() {
        let reconciliation = makeReconciliation()

        reconciliation.deferMissedMessageFetches(["a", "b"])
        reconciliation.deferMissedMessageFetches(["b", "c"])
        XCTAssertEqual(stored(), ["a", "b", "c"])

        reconciliation.clearDeferredMissedMessageIds(["a", "c"])
        XCTAssertEqual(stored(), ["b"])

        reconciliation.clearDeferredMissedMessageIds(["b"])
        XCTAssertNil(defaults.object(forKey: SyncConfig.deferredMissedMessageIdsKey))
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

    private func stored() -> [String]? {
        defaults.stringArray(forKey: SyncConfig.deferredMissedMessageIdsKey)
    }
}
