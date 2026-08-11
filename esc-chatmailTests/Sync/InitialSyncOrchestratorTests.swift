import XCTest
import CoreData
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
                conversationManager: conversationManager,
                migrationFlags: InMemoryMigrationFlagStore(),
                identityAliasProvider: { _ in [normalizedEmail(Self.myEmail)] }
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
    func testHandleSyncCompletion_cleanLedgerReadFailureDoesNotStageInitialCursor() async throws {
        let profile = GmailProfile(
            emailAddress: "initial-sync-test@example.com",
            messagesTotal: 0,
            threadsTotal: 0,
            historyId: "history-held"
        )
        let apiClient = MockGmailAPIClient()
        let conversationManager = ConversationManager(currentUserEmail: { profile.emailAddress })
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
                conversationManager: conversationManager,
                migrationFlags: InMemoryMigrationFlagStore(),
                identityAliasProvider: { _ in [normalizedEmail(profile.emailAddress)] }
            ),
            attachmentDownloader: AttachmentDownloader.shared,
            coreDataStack: coreDataStack,
            failureTracker: failureTracker,
            performanceLogger: .shared
        )
        let failingContext = try FailingReadStore.makeFailingContext()
        let modificationTransaction = await ModificationTracker.shared.beginTransaction()

        let completion = try await sut.handleSyncCompletion(
            result: BatchProcessingResult(totalProcessed: 0, successfulCount: 0, failedIds: []),
            profile: profile,
            labelIds: [],
            modificationTransaction: modificationTransaction,
            context: failingContext
        )

        XCTAssertTrue(completion.hadWarnings)
        let plan = try XCTUnwrap(completion.advancePlan)
        XCTAssertEqual(plan.outcome, .held)

        let store = try XCTUnwrap(
            failingContext.persistentStoreCoordinator?.persistentStores.first as? FailingReadStore
        )
        XCTAssertEqual(
            store.requestTypes,
            [.fetchRequestType],
            "A held plan must prevent the subsequent account-history mutation"
        )

        await ModificationTracker.shared.rollbackTransaction(modificationTransaction)
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
                conversationManager: conversationManager,
                migrationFlags: InMemoryMigrationFlagStore(),
                identityAliasProvider: { _ in [normalizedEmail(profile.emailAddress)] }
            ),
            attachmentDownloader: AttachmentDownloader.shared,
            coreDataStack: coreDataStack,
            failureTracker: failureTracker,
            performanceLogger: .shared
        )

        // A previous failing attempt left durable deferred rows and a counter.
        let previousRun = coreDataStack.newBackgroundContext()
        await failureTracker.recordFailure(fetchFailedIds: ["stale-1", "stale-2"], in: previousRun)
        try await SyncFailureCounterCheckpointStore().stage(
            consecutiveFailureCount: 1,
            accountEmail: profile.emailAddress,
            in: previousRun
        )
        try await coreDataStack.saveAsync(context: previousRun)

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
        let completion = try await sut.handleSyncCompletion(
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

        XCTAssertFalse(completion.hadWarnings)

        // The stale-row cleanup is staged; it commits with the run's save, and
        // success state resets only at the post-save commit.
        try await coreDataStack.saveAsync(context: context)
        let advancePlan = try XCTUnwrap(completion.advancePlan)
        await failureTracker.commit(advancePlan)

        let consecutiveFailureCount = await failureTracker.consecutiveFailureCount
        let lastSuccessfulSyncTime = await failureTracker.lastSuccessfulSyncTime
        XCTAssertEqual(consecutiveFailureCount, 0)
        XCTAssertNotNil(lastSuccessfulSyncTime)
        let durableFailureCount = try await fetchFailureCounter(in: context)
        XCTAssertEqual(durableFailureCount, 0)

        let staleRowCount: Int = await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "AbandonedSyncMessage")
            request.includesPendingChanges = false
            return (try? context.count(for: request)) ?? -1
        }
        XCTAssertEqual(staleRowCount, 0, "A recovered retry must clear the stale deferred rows")

        let historyId: String? = await context.perform {
            let request = Account.fetchRequest()
            request.fetchLimit = 1
            return (try? context.fetch(request).first)?.historyId
        }
        XCTAssertEqual(historyId, profile.historyId)

        await ModificationTracker.shared.rollbackTransaction(modificationTransaction)
    }

    /// A permanent initial-sync failure holds immediately below the escape
    /// threshold, then atomically abandons the failed row and establishes the
    /// history cursor when the threshold is reached.
    @MainActor
    func testHandleSyncCompletion_permanentFailureHoldsThenEscapesAtThreshold() async throws {
        let profile = GmailProfile(
            emailAddress: "initial-sync-test@example.com",
            messagesTotal: 1,
            threadsTotal: 1,
            historyId: "history-200"
        )

        let apiClient = MockGmailAPIClient()
        // Per-id error: persistent across the retry pass's attempts.
        apiClient.getMessageErrors["never-recovers"] = APIError.timeout

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
            messageFetcher: MessageFetcher(apiClient: apiClient, clock: FakeSyncClock()),
            messagePersister: messagePersister,
            conversationManager: conversationManager,
            dataCleanupService: DataCleanupService(
                coreDataStack: coreDataStack,
                conversationManager: conversationManager,
                migrationFlags: InMemoryMigrationFlagStore(),
                identityAliasProvider: { _ in [normalizedEmail(profile.emailAddress)] }
            ),
            attachmentDownloader: AttachmentDownloader.shared,
            coreDataStack: coreDataStack,
            failureTracker: failureTracker,
            performanceLogger: .shared
        )

        let context = coreDataStack.newBackgroundContext()
        try await messagePersister.saveAccount(
            profile: profile,
            aliases: [],
            in: context,
            saveHistoryId: false
        )
        try await coreDataStack.saveAsync(context: context)

        let threshold = SyncConfig.maxConsecutiveSyncFailures
        guard threshold > 1 else {
            XCTFail("The boundary regression requires a hold below the escape threshold")
            return
        }

        let modificationTransaction = await ModificationTracker.shared.beginTransaction()
        let heldCompletion = try await sut.handleSyncCompletion(
            result: BatchProcessingResult(
                totalProcessed: 1,
                successfulCount: 0,
                failedIds: ["never-recovers"]
            ),
            profile: profile,
            labelIds: ["INBOX"],
            modificationTransaction: modificationTransaction,
            priorFailureCount: threshold - 2,
            context: context
        )

        XCTAssertTrue(heldCompletion.hadWarnings)
        let heldPlan = try XCTUnwrap(heldCompletion.advancePlan)
        XCTAssertEqual(heldPlan.outcome, .held)

        // The rows are staged only — durable via the run's final save.
        try await coreDataStack.saveAsync(context: context)

        let rows: [(id: String, state: String?, failureClass: String?)] = await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "AbandonedSyncMessage")
            request.includesPendingChanges = false
            let records = (try? context.fetch(request)) ?? []
            return records.map {
                (
                    id: $0.value(forKey: "gmailMessageId") as? String ?? "",
                    state: $0.value(forKey: "state") as? String,
                    failureClass: $0.value(forKey: "failureClass") as? String
                )
            }
        }
        XCTAssertEqual(rows.map(\.id), ["never-recovers"])
        XCTAssertEqual(rows.first?.state, AbandonedSyncMessage.State.deferred.rawValue)
        XCTAssertEqual(rows.first?.failureClass, AbandonedSyncMessage.FailureClass.fetchFailed.rawValue)

        let consecutiveFailureCount = await failureTracker.consecutiveFailureCount
        XCTAssertEqual(consecutiveFailureCount, 0, "Ledger staging must not mutate UserDefaults")
        let durableFailureCount = try await fetchFailureCounter(in: context)
        XCTAssertEqual(durableFailureCount, threshold - 1, "The failed attempt must count durably")
        let lastSuccessfulSyncTime = await failureTracker.lastSuccessfulSyncTime
        XCTAssertNil(lastSuccessfulSyncTime, "No success state may be recorded on the warnings path")

        let historyId: String? = await context.perform {
            let request = Account.fetchRequest()
            request.fetchLimit = 1
            return (try? context.fetch(request).first)?.historyId
        }
        XCTAssertNil(historyId, "A failure below the threshold must keep historyId unset")

        let abandonedNotification = expectation(
            forNotification: .syncMessagesAbandoned,
            object: nil
        ) { note in
            (note.userInfo?["count"] as? Int) == 1
        }
        let escapedCompletion = try await sut.handleSyncCompletion(
            result: BatchProcessingResult(
                totalProcessed: 1,
                successfulCount: 0,
                failedIds: ["never-recovers"]
            ),
            profile: profile,
            labelIds: ["INBOX"],
            modificationTransaction: modificationTransaction,
            priorFailureCount: threshold - 1,
            context: context
        )

        XCTAssertTrue(escapedCompletion.hadWarnings)
        let escapedPlan = try XCTUnwrap(escapedCompletion.advancePlan)
        XCTAssertEqual(escapedPlan.outcome, .advancedAbandoning(count: 1))

        try await coreDataStack.saveAsync(context: context)
        await failureTracker.commit(escapedPlan)
        await fulfillment(of: [abandonedNotification], timeout: 5)

        let escapedRows: [(id: String, state: String?, reason: String?)] = await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "AbandonedSyncMessage")
            request.includesPendingChanges = false
            let records = (try? context.fetch(request)) ?? []
            return records.map {
                (
                    id: $0.value(forKey: "gmailMessageId") as? String ?? "",
                    state: $0.value(forKey: "state") as? String,
                    reason: $0.value(forKey: "reason") as? String
                )
            }
        }
        XCTAssertEqual(escapedRows.map(\.id), ["never-recovers"])
        XCTAssertEqual(escapedRows.first?.state, AbandonedSyncMessage.State.abandoned.rawValue)
        XCTAssertEqual(escapedRows.first?.reason, "Max sync failures reached")
        let escapedFailureCount = try await fetchFailureCounter(in: context)
        XCTAssertEqual(escapedFailureCount, 0)

        let escapedHistoryId: String? = await context.perform {
            let request = Account.fetchRequest()
            request.fetchLimit = 1
            request.includesPendingChanges = false
            return (try? context.fetch(request).first)?.historyId
        }
        XCTAssertEqual(escapedHistoryId, profile.historyId)
        let successfulSyncTime = await failureTracker.lastSuccessfulSyncTime
        XCTAssertNotNil(successfulSyncTime)

        await ModificationTracker.shared.rollbackTransaction(modificationTransaction)
    }

    /// A warnings completion is not a successful sync: without a committed
    /// history cursor, stamping "now" would make reconciliation and history
    /// recovery start after the message this run failed to fetch.
    @MainActor
    func testPerformSync_warningRunDoesNotRecordSuccessOrNarrowReconciliationWindow() async throws {
        let defaults = UserDefaults.standard
        let successKey = SyncConfig.lastSuccessfulSyncTimeKey
        let cleanupKey = "hasDoneDuplicateCleanupV1"
        let previousSuccess = defaults.object(forKey: successKey)
        let previousCleanup = defaults.object(forKey: cleanupKey)
        defer {
            if let previousSuccess {
                defaults.set(previousSuccess, forKey: successKey)
            } else {
                defaults.removeObject(forKey: successKey)
            }
            if let previousCleanup {
                defaults.set(previousCleanup, forKey: cleanupKey)
            } else {
                defaults.removeObject(forKey: cleanupKey)
            }
        }

        let priorSuccessfulSync = Date().addingTimeInterval(-2 * 60 * 60).timeIntervalSince1970
        let installTimestamp = priorSuccessfulSync - 10 * 60 * 60
        defaults.set(priorSuccessfulSync, forKey: successKey)
        defaults.set(true, forKey: cleanupKey)

        let profile = GmailProfile(
            emailAddress: "initial-sync-warning@example.com",
            messagesTotal: 1,
            threadsTotal: 1,
            historyId: "history-must-remain-unset"
        )
        let apiClient = MockGmailAPIClient()
        apiClient.profileResponse = profile
        apiClient.listMessagesResponse = MessagesListResponse(
            messages: [MessageListItem(id: "never-recovers", threadId: "thread-1")],
            nextPageToken: nil,
            resultSizeEstimate: 1
        )
        apiClient.getMessageErrors["never-recovers"] = APIError.timeout

        let conversationManager = ConversationManager(
            currentUserEmail: { profile.emailAddress }
        )
        let messagePersister = MessagePersister(
            coreDataStack: coreDataStack,
            saveHTML: { _, _ in nil },
            conversationManager: conversationManager
        )
        let sut = InitialSyncOrchestrator(
            messageFetcher: MessageFetcher(apiClient: apiClient, clock: FakeSyncClock()),
            messagePersister: messagePersister,
            conversationManager: conversationManager,
            dataCleanupService: DataCleanupService(
                coreDataStack: coreDataStack,
                conversationManager: conversationManager,
                migrationFlags: InMemoryMigrationFlagStore(),
                identityAliasProvider: { _ in [normalizedEmail(profile.emailAddress)] }
            ),
            attachmentDownloader: AttachmentDownloader(apiClient: apiClient),
            coreDataStack: coreDataStack,
            failureTracker: SyncFailureTracker(defaults: self.defaults, coreDataStack: coreDataStack),
            performanceLogger: .shared
        )

        let result = try await sut.performSync { _, _ in }

        XCTAssertTrue(result.hadWarnings)
        XCTAssertEqual(defaults.double(forKey: successKey), priorSuccessfulSync, accuracy: 0.001)
        XCTAssertEqual(
            SyncTimeCalculator.calculateStartTime(
                config: .reconciliation,
                installTimestamp: installTimestamp
            ),
            priorSuccessfulSync - SyncConfig.timestampBufferSeconds,
            accuracy: 1.0,
            "A warning run must preserve the last verified reconciliation lower bound"
        )

        let context = coreDataStack.newBackgroundContext()
        let historyId: String? = await context.perform {
            let request = Account.fetchRequest()
            request.fetchLimit = 1
            request.includesPendingChanges = false
            return (try? context.fetch(request).first)?.historyId
        }
        XCTAssertNil(historyId)
    }

    /// The success-commit contract through the FULL entry point: `performSync`
    /// itself must commit the staged advance plan after its final save —
    /// resetting the strike counter, stamping the success time, and clearing
    /// recovered deferred rows — with no tracker bookkeeping done by the
    /// caller. The `handleSyncCompletion` tests above perform the caller's
    /// obligations themselves, so only this test guards the orchestrator's
    /// post-save `failureTracker.commit(advancePlan)` call; without it, a later
    /// incremental run's escape hatch would inherit the stale strikes and could
    /// abandon messages on its first failure instead of its third.
    @MainActor
    func testPerformSync_cleanRunAfterPriorFailuresCommitsSuccessState() async throws {
        let profile = GmailProfile(
            emailAddress: "initial-sync-test@example.com",
            messagesTotal: 1,
            threadsTotal: 1,
            historyId: "history-300"
        )

        let apiClient = MockGmailAPIClient()
        apiClient.profileResponse = profile
        apiClient.labelsResponse = [
            GmailLabel(
                id: "INBOX",
                name: "Inbox",
                messageListVisibility: nil,
                labelListVisibility: nil,
                type: "system"
            )
        ]
        apiClient.listMessagesResponse = MessagesListResponse(
            messages: [MessageListItem(id: "m-clean", threadId: "t-clean")],
            nextPageToken: nil,
            resultSizeEstimate: 1
        )
        apiClient.getMessageResponses["m-clean"] = GmailMessageBuilder()
            .withId("m-clean")
            .withThreadId("t-clean")
            .withLabels(["INBOX"])
            .withFrom("sender@example.com", name: "Sender")
            .withTo([profile.emailAddress])
            .withSubject("Clean run")
            .withSnippet("All good")
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
            messageFetcher: MessageFetcher(apiClient: apiClient, clock: FakeSyncClock()),
            messagePersister: messagePersister,
            conversationManager: conversationManager,
            dataCleanupService: DataCleanupService(
                coreDataStack: coreDataStack,
                conversationManager: conversationManager,
                migrationFlags: InMemoryMigrationFlagStore(),
                identityAliasProvider: { _ in [normalizedEmail(profile.emailAddress)] }
            ),
            attachmentDownloader: AttachmentDownloader(apiClient: apiClient),
            coreDataStack: coreDataStack,
            failureTracker: failureTracker,
            performanceLogger: .shared
        )

        // A previous failing attempt left a strike and a durable deferred row.
        let previousRun = coreDataStack.newBackgroundContext()
        await failureTracker.recordFailure(fetchFailedIds: ["stale-1"], in: previousRun)
        try await SyncFailureCounterCheckpointStore().stage(
            consecutiveFailureCount: 1,
            accountEmail: profile.emailAddress,
            in: previousRun
        )
        try await coreDataStack.saveAsync(context: previousRun)
        let seededFailureCount = await failureTracker.consecutiveFailureCount
        XCTAssertEqual(seededFailureCount, 0)
        let seededDurableFailureCount = try await fetchFailureCounter(in: previousRun)
        XCTAssertEqual(seededDurableFailureCount, 1, "Positive control: the prior strike must be seeded")

        let result = try await sut.performSync { _, _ in }

        XCTAssertFalse(result.hadWarnings)

        let consecutiveFailureCount = await failureTracker.consecutiveFailureCount
        XCTAssertEqual(
            consecutiveFailureCount, 0,
            "A clean run must not resurrect the retired UserDefaults counter"
        )
        let lastSuccessfulSyncTime = await failureTracker.lastSuccessfulSyncTime
        XCTAssertNotNil(
            lastSuccessfulSyncTime,
            "A clean run must commit its advance plan and stamp the success time"
        )

        let context = coreDataStack.newBackgroundContext()
        let staleRowCount: Int = await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "AbandonedSyncMessage")
            request.includesPendingChanges = false
            return (try? context.count(for: request)) ?? -1
        }
        XCTAssertEqual(staleRowCount, 0, "The clean run's save must clear the recovered deferred row")

        let historyId: String? = await context.perform {
            let request = Account.fetchRequest()
            request.fetchLimit = 1
            request.includesPendingChanges = false
            return (try? context.fetch(request).first)?.historyId
        }
        XCTAssertEqual(historyId, profile.historyId)
        let durableFailureCount = try await fetchFailureCounter(in: context)
        XCTAssertEqual(durableFailureCount, 0, "A clean run must reset the durable strike counter")
    }

    private func fetchFailureCounter(
        in context: NSManagedObjectContext
    ) async throws -> Int? {
        struct Payload: Decodable {
            let version: Int
            let consecutiveFailureCount: Int
        }

        return try await context.perform {
            let request = SyncCheckpoint.fetchRequest()
            request.predicate = NSPredicate(
                format: "kind == %@",
                SyncFailureCounterCheckpoint.kind
            )
            guard let row = try context.fetch(request).first,
                  let json = row.pendingMessageIdsJSON,
                  let data = json.data(using: .utf8) else {
                return nil
            }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard payload.version == 1 else { return nil }
            return payload.consecutiveFailureCount
        }
    }
}
