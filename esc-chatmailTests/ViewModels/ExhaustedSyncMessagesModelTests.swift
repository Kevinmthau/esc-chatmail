import XCTest
@testable import esc_chatmail

/// The conversation list's banner for mail sync gave up on
/// (`ExhaustedSyncMessagesModel`, `ExhaustedSyncMessagesPolicy`; architecture
/// review 2026-11, sync-persist-path#6). The ledger it reads is pinned in
/// `AbandonedMessageRetryTests`.
@MainActor
final class ExhaustedSyncMessagesModelTests: XCTestCase {
    private var notificationCenter: NotificationCenter!

    override func setUp() {
        super.setUp()
        notificationCenter = NotificationCenter()
    }

    override func tearDown() {
        notificationCenter = nil
        super.tearDown()
    }

    // MARK: - Policy

    func testSummary_noExhaustedMessages_hidesTheBanner() {
        XCTAssertNil(ExhaustedSyncMessagesPolicy.summary(forExhaustedMessageIds: []))
    }

    func testSummary_oneMessage_usesTheSingular() {
        let summary = ExhaustedSyncMessagesPolicy.summary(forExhaustedMessageIds: ["18c0ffee"])

        XCTAssertEqual(summary?.title, "1 message couldn't be downloaded")
        XCTAssertEqual(summary?.firstGmailMessageId, "18c0ffee")
    }

    func testSummary_severalMessages_countsThemAndOpensTheFirst() {
        let summary = ExhaustedSyncMessagesPolicy.summary(forExhaustedMessageIds: ["first", "second", "third"])

        XCTAssertEqual(summary?.title, "3 messages couldn't be downloaded")
        XCTAssertEqual(summary?.firstGmailMessageId, "first")
    }

    // Revert-check: the `authuser` query item in
    // `ExhaustedSyncMessagesPolicy.gmailWebURL` removed fails the first
    // assertion; the fragment set to the bare ID fails the second.
    func testGmailWebURL_opensTheMessageInItsAccount() throws {
        let url = try XCTUnwrap(
            ExhaustedSyncMessagesPolicy.gmailWebURL(forMessageId: "18c0ffee", accountEmail: "me+tag@example.com")
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "authuser", value: "me+tag@example.com")])
        XCTAssertEqual(components.fragment, "all/18c0ffee")
        XCTAssertEqual(components.host, "mail.google.com")
        XCTAssertEqual(components.scheme, "https")
    }

    func testGmailWebURL_withNoAccount_opensTheBrowsersAccount() throws {
        let url = try XCTUnwrap(ExhaustedSyncMessagesPolicy.gmailWebURL(forMessageId: "18c0ffee", accountEmail: nil))

        XCTAssertNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    }

    /// The ID is Gmail's, but the link is built only from a plain hex-like
    /// token all the same: anything else is no link.
    ///
    /// Revert-check: the `allSatisfy` guard in `gmailWebURL` removed.
    func testGmailWebURL_refusesAnIDThatIsNotAPlainToken() {
        XCTAssertNil(ExhaustedSyncMessagesPolicy.gmailWebURL(forMessageId: "abc/../settings", accountEmail: nil))
        XCTAssertNil(ExhaustedSyncMessagesPolicy.gmailWebURL(forMessageId: "", accountEmail: nil))
    }

    // MARK: - Model

    /// Revert-check: the `.syncCompleted` subscription in
    /// `ExhaustedSyncMessagesModel.init` deleted. The banner then stays hidden
    /// after the sync whose drain gave up on a message.
    func testSyncCompleted_showsTheBannerForANewlyExhaustedMessage() async throws {
        let manager = StubExhaustedSyncMessagesManager()
        let model = makeModel(manager: manager)
        model.refresh()
        try await waitUntil { await manager.fetchCount() >= 1 }
        XCTAssertNil(model.summary)

        await manager.setExhaustedIds(["18c0ffee"])
        notificationCenter.post(name: .syncCompleted, object: nil)

        try await waitUntil { model.summary != nil }
        XCTAssertEqual(model.summary?.title, "1 message couldn't be downloaded")
    }

    /// `.syncMessagesAbandoned` had no observer at all before this banner.
    ///
    /// Revert-check: the `.syncMessagesAbandoned` merge in
    /// `ExhaustedSyncMessagesModel.init` deleted.
    func testSyncMessagesAbandoned_refreshesTheBanner() async throws {
        let manager = StubExhaustedSyncMessagesManager(exhaustedIds: ["reabandoned-at-the-cap"])
        let model = makeModel(manager: manager)

        notificationCenter.post(name: .syncMessagesAbandoned, object: nil, userInfo: ["count": 1])

        try await waitUntil { model.summary != nil }
    }

    /// An unreadable ledger, or no account work admitted, keeps what is on
    /// screen: no answer is not an empty ledger.
    ///
    /// Revert-check: `guard let ids else { return }` in
    /// `ExhaustedSyncMessagesModel.publish` removed (an unread answer treated
    /// as none).
    func testUnreadableLedger_keepsTheBanner() async throws {
        let manager = StubExhaustedSyncMessagesManager(exhaustedIds: ["18c0ffee"])
        let model = makeModel(manager: manager)
        model.refresh()
        try await waitUntil { model.summary != nil }

        await manager.setExhaustedIds(nil)
        model.refresh()
        try await waitUntil { await manager.fetchCount() >= 2 }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNotNil(model.summary)
    }

    /// Retry hides the banner at once, gives the rows back and asks for a
    /// sync; a Retry that gave nothing back asks for none.
    ///
    /// Revert-check: the `if gaveBack { self.requestSync() }` in
    /// `ExhaustedSyncMessagesModel.retryAll` removed fails the first half;
    /// the `if gaveBack` dropped fails the second.
    func testRetryAll_hidesTheBanner_andAsksForASyncOnlyWhenRowsWereGivenBack() async throws {
        var syncRequests = 0
        let manager = StubExhaustedSyncMessagesManager(exhaustedIds: ["18c0ffee"], retryAnswer: true)
        let model = makeModel(manager: manager, requestSync: { syncRequests += 1 })
        model.refresh()
        try await waitUntil { model.summary != nil }

        await manager.setExhaustedIds([])
        model.retryAll()

        XCTAssertNil(model.summary, "The banner hides at once")
        try await waitUntil { syncRequests == 1 }
        let retryCalls = await manager.retryCalls
        XCTAssertEqual(retryCalls, 1)

        let nothingToGiveBack = StubExhaustedSyncMessagesManager(exhaustedIds: [], retryAnswer: false)
        let idleModel = makeModel(manager: nothingToGiveBack, requestSync: { syncRequests += 1 })
        idleModel.retryAll()
        try await waitUntil { await nothingToGiveBack.retryCalls == 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(syncRequests, 1)
    }

    func testGmailURL_isTheFirstMessageInTheSignedInAccount() async throws {
        let manager = StubExhaustedSyncMessagesManager(exhaustedIds: ["first", "second"])
        let model = makeModel(manager: manager, accountEmail: { "me@example.com" })
        XCTAssertNil(model.gmailURL, "No banner, no link")
        model.refresh()
        try await waitUntil { model.summary != nil }

        XCTAssertEqual(
            model.gmailURL,
            ExhaustedSyncMessagesPolicy.gmailWebURL(forMessageId: "first", accountEmail: "me@example.com")
        )
    }

    // MARK: - Helpers

    private func makeModel(
        manager: StubExhaustedSyncMessagesManager,
        accountEmail: @escaping @MainActor () -> String? = { nil },
        requestSync: @escaping @MainActor () -> Void = {}
    ) -> ExhaustedSyncMessagesModel {
        ExhaustedSyncMessagesModel(
            manager: manager,
            accountEmail: accountEmail,
            requestSync: requestSync,
            notificationCenter: notificationCenter
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 5.0,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}
