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

/// Every saved page of an initial sync must be fully presentable on its own:
/// conversations carry a snippet and displayName the moment their page save
/// lands, so an interrupted run never strands "No messages" rows.
final class InitialSyncOrchestratorPageDurabilityTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var testStack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!
    private var apiClient: MockGmailAPIClient!

    private static let myEmail = "me@example.com"

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "InitialSyncOrchestratorPageDurabilityTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        testStack = TestCoreDataStack()
        coreDataStack = CoreDataStack(persistentContainerForTesting: testStack.persistentContainer)
        apiClient = MockGmailAPIClient()
        await ModificationTracker.shared.reset()
    }

    override func tearDown() async throws {
        await ModificationTracker.shared.reset()
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        coreDataStack = nil
        testStack = nil
        apiClient = nil
        try await super.tearDown()
    }

    @MainActor
    func testInterruptedRunKeepsSavedPageConversationsPresentable() async throws {
        configureTwoPageMailboxFailingOnSecondPage()
        let sut = makeOrchestrator()

        do {
            _ = try await sut.performSync { _, _ in }
            XCTFail("Expected the page-2 list failure to abort the run")
        } catch {
            // Expected: the run dies between page saves.
        }

        let rows = try await fetchConversationRows()
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertNotNil(
                MessagePreviewText.nonEmpty(row.snippet),
                "Page-1 conversation persisted without a row preview"
            )
            XCTAssertNotNil(
                MessagePreviewText.nonEmpty(row.displayName),
                "Page-1 conversation persisted without a stored display name"
            )
        }

        let historyId = await fetchAccountHistoryId()
        XCTAssertNil(historyId, "Interrupted run must not advance historyId")
    }

    @MainActor
    func testRerunAfterInterruptionConverges() async throws {
        configureTwoPageMailboxFailingOnSecondPage()
        let sut = makeOrchestrator()

        _ = try? await sut.performSync { _, _ in }

        // Page-token errors reset once thrown, so the retry sees page 2 succeed.
        _ = try await sut.performSync { _, _ in }

        let rows = try await fetchConversationRows()
        XCTAssertEqual(rows.count, 3)
        for row in rows {
            XCTAssertNotNil(MessagePreviewText.nonEmpty(row.snippet))
            XCTAssertNotNil(MessagePreviewText.nonEmpty(row.displayName))
        }

        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, "history-500")
    }

    // MARK: - Fixture

    private func configureTwoPageMailboxFailingOnSecondPage() {
        apiClient.profileResponse = GmailProfile(
            emailAddress: Self.myEmail,
            messagesTotal: 3,
            threadsTotal: 3,
            historyId: "history-500"
        )
        apiClient.labelsResponse = [
            GmailLabel(
                id: "INBOX",
                name: "Inbox",
                messageListVisibility: nil,
                labelListVisibility: nil,
                type: "system"
            )
        ]

        apiClient.paginatedListMessagesResponses = [
            "__first_page__": MessagesListResponse(
                messages: [
                    MessageListItem(id: "m1", threadId: "t1"),
                    MessageListItem(id: "m2", threadId: "t2")
                ],
                nextPageToken: "page-2",
                resultSizeEstimate: 3
            ),
            "page-2": MessagesListResponse(
                messages: [MessageListItem(id: "m3", threadId: "t3")],
                nextPageToken: nil,
                resultSizeEstimate: 3
            )
        ]
        apiClient.listMessagesErrorsByPageToken = ["page-2": APIError.timeout]

        apiClient.getMessageResponses = [
            "m1": GmailMessageBuilder()
                .withId("m1")
                .withThreadId("t1")
                .withLabels(["INBOX"])
                .withFrom("alice@example.com", name: "Alice Smith")
                .withTo([Self.myEmail])
                .withSubject("Lunch plans")
                .withSnippet("See you at noon")
                .build(),
            "m2": GmailMessageBuilder()
                .withId("m2")
                .withThreadId("t2")
                .withLabels(["INBOX"])
                .withFrom("bob@example.com", name: "Bob Jones")
                .withTo([Self.myEmail])
                .withSubject("Standup notes")
                .withSnippet("Moved to 10am")
                .build(),
            "m3": GmailMessageBuilder()
                .withId("m3")
                .withThreadId("t3")
                .withLabels(["INBOX"])
                .withFrom("carol@example.com", name: "Carol King")
                .withTo([Self.myEmail])
                .withSubject("Design review")
                .withSnippet("Figma link inside")
                .build()
        ]
    }

    @MainActor
    private func makeOrchestrator() -> InitialSyncOrchestrator {
        let conversationManager = ConversationManager(
            currentUserEmail: { Self.myEmail }
        )
        let messagePersister = MessagePersister(
            coreDataStack: coreDataStack,
            saveHTML: { _, _ in nil },
            conversationManager: conversationManager
        )
        return InitialSyncOrchestrator(
            messageFetcher: MessageFetcher(apiClient: apiClient),
            messagePersister: messagePersister,
            conversationManager: conversationManager,
            dataCleanupService: DataCleanupService(
                coreDataStack: coreDataStack,
                conversationManager: conversationManager
            ),
            attachmentDownloader: AttachmentDownloader(apiClient: apiClient),
            coreDataStack: coreDataStack,
            failureTracker: SyncFailureTracker(defaults: defaults, coreDataStack: coreDataStack),
            performanceLogger: .shared
        )
    }

    private struct ConversationRow: Sendable {
        let snippet: String?
        let displayName: String?
    }

    private func fetchConversationRows() async throws -> [ConversationRow] {
        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            let request = Conversation.fetchRequest()
            request.includesPendingChanges = false
            let conversations = (try? context.fetch(request)) ?? []
            return conversations.map {
                ConversationRow(snippet: $0.snippet, displayName: $0.displayName)
            }
        }
    }

    private func fetchAccountHistoryId() async -> String? {
        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            let request = Account.fetchRequest()
            request.fetchLimit = 1
            return (try? context.fetch(request).first)?.historyId
        }
    }
}

final class InitialSyncOrchestratorFailureTrackerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var testStack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "InitialSyncOrchestratorFailureTrackerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        // Isolated per-test stack. Operating on CoreDataStack.shared here
        // (previously via destroyAndReloadAsync) tears the shared store out
        // from under concurrently scheduled work and leaks async Core Data
        // activity into whatever test class runs next in this process.
        testStack = TestCoreDataStack()
        coreDataStack = CoreDataStack(persistentContainerForTesting: testStack.persistentContainer)
        await ModificationTracker.shared.reset()
    }

    override func tearDown() async throws {
        await ModificationTracker.shared.reset()
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        coreDataStack = nil
        testStack = nil
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
            coreDataStack: coreDataStack,
            saveHTML: { _, _ in nil },
            conversationManager: conversationManager
        )
        let failureTracker = SyncFailureTracker(defaults: defaults, coreDataStack: coreDataStack)
        let sut = InitialSyncOrchestrator(
            messageFetcher: MessageFetcher(apiClient: apiClient),
            messagePersister: messagePersister,
            conversationManager: conversationManager,
            dataCleanupService: DataCleanupService(
                coreDataStack: coreDataStack,
                conversationManager: conversationManager
            ),
            attachmentDownloader: AttachmentDownloader.shared,
            coreDataStack: coreDataStack,
            failureTracker: failureTracker,
            performanceLogger: .shared
        )

        await failureTracker.recordFailure(failedIds: ["stale-1", "stale-2"])

        let context = coreDataStack.newBackgroundContext()
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
        try await coreDataStack.saveAsync(context: context)

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
