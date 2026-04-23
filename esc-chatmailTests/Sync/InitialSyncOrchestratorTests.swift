import XCTest
@testable import esc_chatmail

final class InitialSyncOrchestratorTests: XCTestCase {
    func testCompletionDisposition_warnedInitialSyncKeepsHistoryIdUnset() {
        let disposition = InitialSyncOrchestrator.completionDisposition(
            hadInitialFailures: true,
            permanentlyFailedCount: 1
        )

        XCTAssertEqual(
            disposition,
            InitialSyncCompletionDisposition(
                shouldAdvanceHistoryId: false,
                hadWarnings: true
            )
        )
    }

    func testCompletionDisposition_recoveredFailuresClearWarningsButKeepHistoryAdvance() {
        let disposition = InitialSyncOrchestrator.completionDisposition(
            hadInitialFailures: true,
            permanentlyFailedCount: 0
        )

        XCTAssertEqual(
            disposition,
            InitialSyncCompletionDisposition(
                shouldAdvanceHistoryId: true,
                hadWarnings: false
            )
        )
    }
}

final class InitialSyncOrchestratorFailureTrackerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "InitialSyncOrchestratorFailureTrackerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        await ModificationTracker.shared.reset()
        try await CoreDataStack.shared.destroyAndReloadAsync()
    }

    override func tearDown() async throws {
        await ModificationTracker.shared.reset()
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try? await CoreDataStack.shared.destroyAndReloadAsync()
        try await super.tearDown()
    }

    @MainActor
    func testHandleSyncCompletion_recoveredRetryClearsStaleFailureTrackerState() async throws {
        let profile = GmailProfile(
            emailAddress: "initial-sync-test@example.com",
            messagesTotal: 1,
            threadsTotal: 1,
            historyId: "history-200"
        )

        let apiClient = MockGmailAPIClient()
        apiClient.getMessageError = APIError.timeout
        apiClient.getMessageResponses["recover-me"] = GmailMessageBuilder()
            .withId("recover-me")
            .withThreadId("thread-recover")
            .withLabels(["INBOX"])
            .withFrom("sender@example.com", name: "Sender")
            .withTo([profile.emailAddress])
            .withSubject("Recovered message")
            .build()

        let conversationManager = ConversationManager(
            currentUserEmail: { profile.emailAddress }
        )
        let messagePersister = MessagePersister(
            coreDataStack: .shared,
            saveHTML: { _, _ in nil },
            conversationManager: conversationManager
        )
        let failureTracker = SyncFailureTracker(defaults: defaults, coreDataStack: .shared)
        let sut = InitialSyncOrchestrator(
            messageFetcher: MessageFetcher(apiClient: apiClient),
            messagePersister: messagePersister,
            conversationManager: conversationManager,
            dataCleanupService: DataCleanupService(
                coreDataStack: .shared,
                conversationManager: conversationManager
            ),
            attachmentDownloader: AttachmentDownloader.shared,
            coreDataStack: .shared,
            failureTracker: failureTracker,
            performanceLogger: .shared
        )

        await failureTracker.recordFailure(failedIds: ["stale-1", "stale-2"])

        let context = CoreDataStack.shared.newBackgroundContext()
        try await messagePersister.saveAccount(
            profile: profile,
            aliases: [],
            in: context,
            saveHistoryId: false
        )
        await messagePersister.saveLabels(
            [
                GmailLabel(
                    id: "INBOX",
                    name: "Inbox",
                    messageListVisibility: nil,
                    labelListVisibility: nil,
                    type: "system"
                )
            ],
            in: context
        )
        try await CoreDataStack.shared.saveAsync(context: context)

        let modificationTransaction = await ModificationTracker.shared.beginTransaction()
        let hadWarnings = await sut.handleSyncCompletion(
            result: BatchProcessingResult(
                totalProcessed: 1,
                successfulCount: 0,
                failedIds: ["recover-me"]
            ),
            profile: profile,
            labelIds: ["INBOX"],
            modificationTransaction: modificationTransaction,
            context: context
        )

        XCTAssertFalse(hadWarnings)
        let consecutiveFailureCount = await failureTracker.consecutiveFailureCount
        let persistentFailedIds = await failureTracker.persistentFailedIds
        let lastSuccessfulSyncTime = await failureTracker.lastSuccessfulSyncTime
        XCTAssertEqual(consecutiveFailureCount, 0)
        XCTAssertEqual(persistentFailedIds, [])
        XCTAssertNotNil(lastSuccessfulSyncTime)

        let historyId: String? = await context.perform {
            let request = Account.fetchRequest()
            request.fetchLimit = 1
            return (try? context.fetch(request).first)?.historyId
        }
        XCTAssertEqual(historyId, profile.historyId)

        await ModificationTracker.shared.rollbackTransaction(modificationTransaction)
    }
}
