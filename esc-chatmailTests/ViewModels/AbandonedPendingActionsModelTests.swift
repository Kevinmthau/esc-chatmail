import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class AbandonedPendingActionsModelTests: XCTestCase {
    private var testStack: TestCoreDataStack!
    private var notificationCenter: NotificationCenter!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        notificationCenter = NotificationCenter()
    }

    override func tearDown() {
        notificationCenter = nil
        testStack = nil
        super.tearDown()
    }

    // MARK: - Policy

    func testSummary_noAbandonedActions_hidesBanner() {
        XCTAssertNil(AbandonedPendingActionsPolicy.summary(forActionDescriptions: []))
    }

    func testSummary_singleAction_usesSingular() {
        let summary = AbandonedPendingActionsPolicy.summary(forActionDescriptions: ["Archive conversation"])

        XCTAssertEqual(summary?.title, "1 change didn't reach Gmail")
        XCTAssertEqual(summary?.detail, "Archive conversation")
    }

    func testSummary_namesEachKindOnceInFirstSeenOrder() {
        let summary = AbandonedPendingActionsPolicy.summary(forActionDescriptions: [
            "Report spam", "Archive conversation", "Report spam"
        ])

        XCTAssertEqual(summary?.title, "3 changes didn't reach Gmail")
        XCTAssertEqual(summary?.detail, "Report spam, Archive conversation")
    }

    // MARK: - Model

    /// Revert-check: deleting the `.pendingActionFailed` subscription in
    /// `AbandonedPendingActionsModel.init` leaves the banner hidden after an
    /// action is abandoned.
    func testPendingActionFailed_showsBannerForNewlyAbandonedAction() async throws {
        let manager = AbandonedActionsManagerSpy()
        let model = AbandonedPendingActionsModel(manager: manager, notificationCenter: notificationCenter)
        model.refresh()
        try await waitUntil { await manager.fetchCount == 1 }
        XCTAssertNil(model.summary)

        await manager.setActions([makeInfo(.archiveConversation)])
        notificationCenter.post(name: .pendingActionFailed, object: nil)

        try await waitUntil { model.summary != nil }
        XCTAssertEqual(model.summary?.title, "1 change didn't reach Gmail")
        XCTAssertEqual(model.summary?.detail, "Archive conversation")
    }

    func testDismissAll_hidesBannerAndDeletesAbandonedActions() async throws {
        let manager = AbandonedActionsManagerSpy()
        await manager.setActions([makeInfo(.reportSpam), makeInfo(.markRead)])
        let model = AbandonedPendingActionsModel(manager: manager, notificationCenter: notificationCenter)
        model.refresh()
        try await waitUntil { model.summary != nil }

        model.dismissAll()

        XCTAssertNil(model.summary, "The banner hides at once")
        try await waitUntil {
            let dismissCount = await manager.dismissCount
            let fetchCount = await manager.fetchCount
            return dismissCount == 1 && fetchCount == 2
        }
        XCTAssertNil(model.summary)
    }

    /// A retry that fails again brings the banner back once the queue has
    /// abandoned the action a second time.
    func testRetryAll_rereadsAfterTheRetryFinishes() async throws {
        let manager = AbandonedActionsManagerSpy()
        await manager.setActions([makeInfo(.archiveConversation)])
        await manager.keepActionsOnRetry()
        let model = AbandonedPendingActionsModel(manager: manager, notificationCenter: notificationCenter)
        model.refresh()
        try await waitUntil { model.summary != nil }

        model.retryAll()

        XCTAssertNil(model.summary)
        try await waitUntil {
            let retryCount = await manager.retryCount
            let fetchCount = await manager.fetchCount
            return retryCount == 1 && fetchCount == 2
        }
        try await waitUntil { model.summary != nil }
        XCTAssertEqual(model.summary?.detail, "Archive conversation")
    }

    // MARK: - Helpers

    private func makeInfo(_ actionType: PendingAction.ActionType) -> AbandonedActionInfo {
        let context = testStack.viewContext
        let objectID = context.performAndWait {
            PendingActionBuilder()
                .withActionType(actionType.rawValue)
                .withStatus("abandoned")
                .build(in: context)
                .objectID
        }
        return AbandonedActionInfo(
            id: objectID,
            actionType: actionType,
            messageId: nil,
            conversationId: nil,
            createdAt: Date(),
            retryCount: 5
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

private actor AbandonedActionsManagerSpy: AbandonedPendingActionsManaging {
    private var actions: [AbandonedActionInfo] = []
    private var retryKeepsActions = false
    private(set) var fetchCount = 0
    private(set) var retryCount = 0
    private(set) var dismissCount = 0

    func setActions(_ actions: [AbandonedActionInfo]) {
        self.actions = actions
    }

    func keepActionsOnRetry() {
        retryKeepsActions = true
    }

    func fetchAbandonedActions() -> [AbandonedActionInfo] {
        fetchCount += 1
        return actions
    }

    func retryAllAbandonedActions() {
        retryCount += 1
        if !retryKeepsActions {
            actions = []
        }
    }

    func dismissAllAbandonedActions() {
        dismissCount += 1
        actions = []
    }
}
