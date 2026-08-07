import XCTest
import BackgroundTasks
import CoreData
@testable import esc_chatmail

final class BackgroundSyncManagerTests: XCTestCase {
    private static let partialQuery = "after:123 -label:spam -label:drafts -label:trash"

    private var testStack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var apiClient: MockGmailAPIClient!
    private var taskScheduler: BackgroundTaskSchedulerSpy!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        coreDataStack = CoreDataStack(
            persistentContainerForTesting: testStack.persistentContainer
        )
        defaultsSuiteName = "BackgroundSyncManagerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        apiClient = MockGmailAPIClient()
        taskScheduler = BackgroundTaskSchedulerSpy()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        taskScheduler = nil
        apiClient = nil
        defaults = nil
        defaultsSuiteName = nil
        coreDataStack = nil
        testStack = nil
        super.tearDown()
    }

    func testCompletionDisposition_truncationStoresContinuationAndSchedulesCatchUpRetry() {
        let continuationState = BackgroundSyncContinuationState.history(
            startHistoryId: "history-100",
            pageToken: "page-2"
        )
        let disposition = BackgroundSyncManager.completionDisposition(
            catchUpState: continuationState,
            hadFetchFailures: false,
            latestHistoryId: "history-123"
        )

        XCTAssertEqual(
            disposition,
            BackgroundSyncCompletionDisposition(
                historyIdToStore: nil,
                continuationState: continuationState,
                retryAction: .catchUp,
                shouldResetRetryState: false
            )
        )
    }

    func testCompletionDisposition_failuresUseFailureBackoff() {
        let disposition = BackgroundSyncManager.completionDisposition(
            hadFetchFailures: true,
            latestHistoryId: "history-123"
        )

        XCTAssertEqual(
            disposition,
            BackgroundSyncCompletionDisposition(
                historyIdToStore: nil,
                continuationState: nil,
                retryAction: .failureBackoff,
                shouldResetRetryState: false
            )
        )
    }

    func testCompletionDisposition_successAdvancesHistoryIdAndResetsRetryState() {
        let disposition = BackgroundSyncManager.completionDisposition(
            hadFetchFailures: false,
            latestHistoryId: "history-123"
        )

        XCTAssertEqual(
            disposition,
            BackgroundSyncCompletionDisposition(
                historyIdToStore: "history-123",
                continuationState: nil,
                retryAction: .none,
                shouldResetRetryState: true
            )
        )
    }

    func testBlockedBackgroundSync_schedulesRetryOnlyForPendingActions() {
        XCTAssertTrue(
            BackgroundSyncManager.shouldScheduleRetryWhenBlocked(by: .pendingActions)
        )
        XCTAssertFalse(
            BackgroundSyncManager.shouldScheduleRetryWhenBlocked(by: .foregroundIncremental)
        )
        XCTAssertFalse(
            BackgroundSyncManager.shouldScheduleRetryWhenBlocked(by: .background)
        )
        XCTAssertTrue(
            BackgroundSyncManager.shouldScheduleRetryWhenBlocked(by: nil)
        )
    }

    func testHistoryContinuationCompatibility_requiresMatchingAccountAndCursor() {
        let continuationState = BackgroundSyncContinuationState.history(
            startHistoryId: "history-100",
            pageToken: "page-2",
            accountEmail: "user@example.com"
        )

        XCTAssertTrue(
            continuationState.isCompatible(
                storedHistoryId: "history-100",
                currentAccountEmail: "user@example.com"
            )
        )
        XCTAssertFalse(
            continuationState.isCompatible(
                storedHistoryId: "history-101",
                currentAccountEmail: "user@example.com"
            )
        )
        XCTAssertFalse(
            continuationState.isCompatible(
                storedHistoryId: "history-100",
                currentAccountEmail: "other@example.com"
            )
        )
    }

    func testPartialContinuationCompatibility_requiresSameAccountAndSourceCursor() {
        let continuationState = BackgroundSyncContinuationState.partial(
            query: "after:123 -label:spam",
            pageToken: "page-2",
            maxResults: 50,
            startHistoryId: "history-expired",
            watermarkHistoryId: "history-watermark",
            accountEmail: "user@example.com"
        )

        XCTAssertTrue(
            continuationState.isCompatible(
                storedHistoryId: "history-expired",
                currentAccountEmail: "user@example.com"
            )
        )
        XCTAssertFalse(
            continuationState.isCompatible(
                storedHistoryId: "history-advanced",
                currentAccountEmail: "user@example.com"
            )
        )
        XCTAssertFalse(
            continuationState.isCompatible(
                storedHistoryId: "history-expired",
                currentAccountEmail: "other@example.com"
            )
        )

        let initialSyncContinuation = BackgroundSyncContinuationState.partial(
            query: "after:123 -label:spam",
            pageToken: nil,
            maxResults: 50,
            startHistoryId: nil,
            watermarkHistoryId: "history-watermark",
            accountEmail: "user@example.com"
        )
        XCTAssertTrue(
            initialSyncContinuation.isCompatible(
                storedHistoryId: nil,
                currentAccountEmail: "user@example.com"
            )
        )
    }

    func testContinuationCompatibility_rejectsUnscopedState() {
        let continuationState = BackgroundSyncContinuationState.partial(
            query: "after:123 -label:spam",
            pageToken: "page-2",
            maxResults: 50,
            startHistoryId: nil,
            watermarkHistoryId: "history-watermark"
        )

        XCTAssertFalse(
            continuationState.isCompatible(
                storedHistoryId: nil,
                currentAccountEmail: "user@example.com"
            )
        )
    }

    // MARK: - Partial-sync watermark integration

    func testPartialSync_capturesWatermarkBeforeListingAndStoresCanonicalProfileEmail() async throws {
        apiClient.profileResponse = makeProfile(
            email: "Canonical.User@example.com",
            historyId: "history-watermark"
        )
        apiClient.listMessagesResponse = emptyMessagePage(nextPageToken: nil)

        let success = await makeManager().performPartialSync(
            query: Self.partialQuery,
            startHistoryId: nil,
            isProcessingTask: false,
            accountEmail: "canonical.user@EXAMPLE.COM"
        )

        XCTAssertTrue(success)
        XCTAssertEqual(apiClient.endpointCallOrder, ["getProfile", "listMessages"])
        XCTAssertEqual(apiClient.getProfileCallCount, 1)
        XCTAssertEqual(apiClient.listMessagesCallCount, 1)
        XCTAssertNil(makeStateManager().getContinuationState())

        let accounts = try await fetchAccountSnapshots()
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.email, "Canonical.User@example.com")
        XCTAssertEqual(accounts.first?.historyId, "history-watermark")
    }

    func testPartialSync_rejectsMismatchedProfileAccountBeforeListingOrCheckpointing() async throws {
        apiClient.profileResponse = makeProfile(
            email: "canonical@example.com",
            historyId: "history-watermark"
        )
        apiClient.listMessagesResponse = emptyMessagePage(nextPageToken: nil)

        let success = await makeManager().performPartialSync(
            query: Self.partialQuery,
            startHistoryId: nil,
            isProcessingTask: false,
            accountEmail: "different@example.com"
        )

        XCTAssertFalse(success)
        XCTAssertEqual(apiClient.endpointCallOrder, ["getProfile"])
        XCTAssertEqual(apiClient.listMessagesCallCount, 0)
        XCTAssertNil(makeStateManager().getContinuationState())
        let accounts = try await fetchAccountSnapshots()
        XCTAssertTrue(accounts.isEmpty)
    }

    func testPartialSync_listFailureRetainsInitialCheckpointCapturedBeforeEnumeration() async throws {
        try await makeStateManager().storeHistoryId(
            "history-expired",
            accountEmail: "user@example.com"
        )
        apiClient.profileResponse = makeProfile(
            email: "user@example.com",
            historyId: "history-watermark"
        )
        apiClient.listMessagesError = APIError.timeout

        let manager = makeManager()
        let success = await manager.performPartialSync(
            query: Self.partialQuery,
            startHistoryId: "history-expired",
            isProcessingTask: false,
            accountEmail: "user@example.com"
        )

        XCTAssertFalse(success)
        XCTAssertEqual(apiClient.endpointCallOrder, ["getProfile", "listMessages"])
        XCTAssertEqual(
            makeStateManager().getContinuationState(),
            BackgroundSyncContinuationState.partial(
                query: Self.partialQuery,
                pageToken: nil,
                maxResults: 50,
                startHistoryId: "history-expired",
                watermarkHistoryId: "history-watermark",
                accountEmail: "user@example.com"
            )
        )
        let storedHistoryId = await makeStateManager().getStoredHistoryId()
        XCTAssertEqual(storedHistoryId, "history-expired")

        let checkpoint = try XCTUnwrap(makeStateManager().getContinuationState())
        let checkpointQuery = try XCTUnwrap(checkpoint.query)
        let checkpointMaxResults = try XCTUnwrap(checkpoint.maxResults)
        let checkpointWatermark = try XCTUnwrap(checkpoint.watermarkHistoryId)
        apiClient.profileResponse = makeProfile(
            email: "user@example.com",
            historyId: "history-must-not-be-used"
        )
        apiClient.listMessagesResponse = emptyMessagePage(nextPageToken: nil)

        let retrySucceeded = await manager.performPartialSync(
            query: checkpointQuery,
            initialPageToken: checkpoint.pageToken,
            maxResults: checkpointMaxResults,
            startHistoryId: checkpoint.startHistoryId,
            watermarkHistoryId: checkpointWatermark,
            isProcessingTask: false,
            accountEmail: checkpoint.accountEmail
        )

        XCTAssertTrue(retrySucceeded)
        XCTAssertEqual(apiClient.getProfileCallCount, 1)
        XCTAssertEqual(apiClient.endpointCallOrder, ["getProfile", "listMessages", "listMessages"])
        let retriedHistoryId = await makeStateManager().getStoredHistoryId()
        XCTAssertEqual(retriedHistoryId, "history-watermark")
        XCTAssertNil(makeStateManager().getContinuationState())
    }

    func testPartialSync_messageFetchFailureRetainsOriginalCheckpointAndWatermark() async throws {
        try await makeStateManager().storeHistoryId(
            "history-expired",
            accountEmail: "user@example.com"
        )
        apiClient.profileResponse = makeProfile(
            email: "user@example.com",
            historyId: "history-watermark"
        )
        apiClient.listMessagesResponse = MessagesListResponse(
            messages: [MessageListItem(id: "message-1", threadId: "thread-1")],
            nextPageToken: nil,
            resultSizeEstimate: 1
        )
        apiClient.getMessageError = APIError.timeout

        let success = await makeManager().performPartialSync(
            query: Self.partialQuery,
            startHistoryId: "history-expired",
            isProcessingTask: false,
            accountEmail: "user@example.com"
        )

        XCTAssertFalse(success)
        XCTAssertEqual(apiClient.getProfileCallCount, 1)
        XCTAssertEqual(apiClient.getMessageCallCount, 1)
        XCTAssertEqual(
            makeStateManager().getContinuationState(),
            BackgroundSyncContinuationState.partial(
                query: Self.partialQuery,
                pageToken: nil,
                maxResults: 50,
                startHistoryId: "history-expired",
                watermarkHistoryId: "history-watermark",
                accountEmail: "user@example.com"
            )
        )
        let storedHistoryId = await makeStateManager().getStoredHistoryId()
        XCTAssertEqual(storedHistoryId, "history-expired")
    }

    func testPartialSync_resumesTruncatedCheckpointWithoutRecapturingWatermark() async throws {
        try await makeStateManager().storeHistoryId(
            "history-expired",
            accountEmail: "user@example.com"
        )
        apiClient.profileResponse = makeProfile(
            email: "user@example.com",
            historyId: "history-watermark"
        )
        apiClient.listMessagesResponse = emptyMessagePage(nextPageToken: "page-2")
        apiClient.paginatedListMessagesResponses = [
            "page-2": emptyMessagePage(nextPageToken: "page-3"),
            "page-3": emptyMessagePage(nextPageToken: "page-4"),
            "page-4": emptyMessagePage(nextPageToken: nil)
        ]

        let manager = makeManager()
        let firstRunSucceeded = await manager.performPartialSync(
            query: Self.partialQuery,
            startHistoryId: "history-expired",
            isProcessingTask: false,
            accountEmail: "user@example.com"
        )

        XCTAssertFalse(firstRunSucceeded)
        XCTAssertEqual(apiClient.getProfileCallCount, 1)
        XCTAssertEqual(apiClient.listMessagesCallCount, 3)
        XCTAssertEqual(taskScheduler.retryBackoffs, [BackgroundSyncManager.catchUpRetryDelay])

        guard let checkpoint = makeStateManager().getContinuationState(),
              let checkpointQuery = checkpoint.query,
              let checkpointMaxResults = checkpoint.maxResults,
              let checkpointWatermark = checkpoint.watermarkHistoryId else {
            XCTFail("Expected a complete partial-sync checkpoint")
            return
        }
        XCTAssertEqual(checkpoint.pageToken, "page-4")
        XCTAssertEqual(checkpoint.startHistoryId, "history-expired")
        XCTAssertEqual(checkpointWatermark, "history-watermark")

        apiClient.profileResponse = makeProfile(
            email: "user@example.com",
            historyId: "history-must-not-be-used"
        )
        let resumedRunSucceeded = await manager.performPartialSync(
            query: checkpointQuery,
            initialPageToken: checkpoint.pageToken,
            maxResults: checkpointMaxResults,
            startHistoryId: checkpoint.startHistoryId,
            watermarkHistoryId: checkpointWatermark,
            isProcessingTask: false,
            accountEmail: checkpoint.accountEmail
        )

        XCTAssertTrue(resumedRunSucceeded)
        XCTAssertEqual(apiClient.getProfileCallCount, 1)
        XCTAssertEqual(apiClient.listMessagesCallCount, 4)
        XCTAssertEqual(apiClient.listMessagesLastPageToken, "page-4")
        XCTAssertEqual(
            apiClient.endpointCallOrder,
            ["getProfile", "listMessages", "listMessages", "listMessages", "listMessages"]
        )
        let storedHistoryId = await makeStateManager().getStoredHistoryId()
        XCTAssertEqual(storedHistoryId, "history-watermark")
        XCTAssertNil(makeStateManager().getContinuationState())
    }

    func testPartialSync_profileFailureAbortsBeforeListingOrCheckpointing() async throws {
        apiClient.getProfileError = APIError.timeout
        apiClient.listMessagesResponse = emptyMessagePage(nextPageToken: nil)

        let success = await makeManager().performPartialSync(
            query: Self.partialQuery,
            startHistoryId: nil,
            isProcessingTask: false,
            accountEmail: "user@example.com"
        )

        XCTAssertFalse(success)
        XCTAssertEqual(apiClient.endpointCallOrder, ["getProfile"])
        XCTAssertEqual(apiClient.listMessagesCallCount, 0)
        XCTAssertNil(makeStateManager().getContinuationState())
        let accounts = try await fetchAccountSnapshots()
        XCTAssertTrue(accounts.isEmpty)
    }

    private func makeManager() -> BackgroundSyncManager {
        let apiClient = apiClient!
        let syncCoordinator = BackgroundSyncNoopCoordinator()
        return BackgroundSyncManager(
            taskScheduler: taskScheduler,
            coreDataStack: coreDataStack,
            defaults: defaults,
            syncRunCoordinator: SyncRunCoordinator(),
            apiClientProvider: { apiClient },
            syncCoordinatorProvider: { syncCoordinator }
        )
    }

    private func makeStateManager() -> BackgroundSyncStateManager {
        BackgroundSyncStateManager(
            coreDataStack: coreDataStack,
            defaults: defaults
        )
    }

    private func fetchAccountSnapshots() async throws -> [BackgroundAccountSnapshot] {
        let context = testStack.newBackgroundContext()
        return try await context.perform {
            let request: NSFetchRequest<Account> = Account.fetchRequest()
            return try context.fetch(request).map {
                BackgroundAccountSnapshot(email: $0.email, historyId: $0.historyId)
            }
        }
    }

    private func makeProfile(email: String, historyId: String) -> GmailProfile {
        GmailProfile(
            emailAddress: email,
            messagesTotal: 0,
            threadsTotal: 0,
            historyId: historyId
        )
    }

    private func emptyMessagePage(nextPageToken: String?) -> MessagesListResponse {
        MessagesListResponse(
            messages: [],
            nextPageToken: nextPageToken,
            resultSizeEstimate: 0
        )
    }
}

private struct BackgroundAccountSnapshot {
    let email: String
    let historyId: String?
}

private final class BackgroundTaskSchedulerSpy: BackgroundTaskScheduling {
    var onAppRefresh: ((BGAppRefreshTask) -> Void)?
    var onProcessing: ((BGProcessingTask) -> Void)?

    private(set) var retryBackoffs: [TimeInterval] = []

    func registerBackgroundTasks() {}
    func scheduleAppRefresh() {}
    func scheduleProcessingTask() {}

    func scheduleRetryAfterBackoff(_ backoff: TimeInterval) {
        retryBackoffs.append(backoff)
    }
}

private final class BackgroundSyncNoopCoordinator: @unchecked Sendable, BackgroundSyncMessageCoordinating {
    func prefetchLabelIdsForBackground(in context: NSManagedObjectContext) async -> Set<String> {
        []
    }

    func saveMessage(
        _ gmailMessage: GmailMessage,
        labelIds: Set<String>?,
        modificationTransaction: ModificationTracker.Transaction,
        in context: NSManagedObjectContext
    ) async throws -> MessagePersistDisposition {
        .persisted
    }

    func updateConversationRollups(
        conversationIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext
    ) async {}

    func updateConversationDisplayNames(
        conversationIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext
    ) async {}
}
