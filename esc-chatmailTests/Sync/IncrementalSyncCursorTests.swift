import XCTest
import CoreData
@testable import esc_chatmail

/// End-to-end characterization of incremental sync's historyId cursor
/// decision, pinned before the reliability refactor changes the contract:
///
/// - a clean run advances the cursor to Gmail's latest historyId,
/// - fetch failures freeze the cursor (below the 3-strikes threshold),
/// - a truncated history collection freezes the cursor WITHOUT consulting the
///   failure tracker (no success recorded, no failure counted).
final class IncrementalSyncCursorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var testStack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!
    private var apiClient: MockGmailAPIClient!
    private var failureTracker: SyncFailureTracker!

    private static let myEmail = "me@example.com"
    private static let startingHistoryId = "1000"

    /// The reconciliation phase stamps `lastReconciliationTime` into
    /// `UserDefaults.standard` (IncrementalSyncOrchestrator) — snapshot and
    /// restore it so runs here don't leak state into other suites.
    private var savedReconciliationTime: Any?

    override func setUp() async throws {
        try await super.setUp()
        savedReconciliationTime = UserDefaults.standard.object(forKey: SyncConfig.lastReconciliationTimeKey)
        suiteName = "IncrementalSyncCursorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        // SQLite store: the post-sync cleanup issues NSBatchDeleteRequests,
        // which the in-memory store type rejects.
        testStack = TestCoreDataStack(storeKind: .sqlite)
        coreDataStack = CoreDataStack(persistentContainerForTesting: testStack.persistentContainer)
        apiClient = MockGmailAPIClient()
        failureTracker = SyncFailureTracker(defaults: defaults, coreDataStack: coreDataStack)
        await ModificationTracker.shared.reset()
        try await seedAccount()
    }

    override func tearDown() async throws {
        await ModificationTracker.shared.reset()
        if let savedReconciliationTime {
            UserDefaults.standard.set(savedReconciliationTime, forKey: SyncConfig.lastReconciliationTimeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SyncConfig.lastReconciliationTimeKey)
        }
        savedReconciliationTime = nil
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        failureTracker = nil
        apiClient = nil
        coreDataStack = nil
        testStack = nil
        try await super.tearDown()
    }

    // MARK: - Scenarios

    @MainActor
    func testCleanRunAdvancesCursorToLatestHistoryId() async throws {
        apiClient.setHistoryResponsesByPageToken([
            (
                pageToken: nil,
                response: HistoryResponse(
                    history: [
                        HistoryRecord(
                            id: "5000",
                            messages: nil,
                            messagesAdded: [HistoryMessageAdded(message: makeHistoryStub(id: "m-new"))],
                            messagesDeleted: nil,
                            labelsAdded: nil,
                            labelsRemoved: nil
                        )
                    ],
                    nextPageToken: nil,
                    historyId: "2000"
                )
            )
        ])
        apiClient.getMessageResponses["m-new"] = makeFullMessage(id: "m-new")

        let sut = makeOrchestrator()
        let result = try await sut.performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
        )

        XCTAssertEqual(result.newMessagesCount, 1)
        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, "2000")
        let lastSuccess = await failureTracker.lastSuccessfulSyncTime
        XCTAssertNotNil(lastSuccess)
    }

    @MainActor
    func testFetchFailuresFreezeCursorBelowEscapeThreshold() async throws {
        apiClient.setHistoryResponsesByPageToken([
            (
                pageToken: nil,
                response: HistoryResponse(
                    history: [
                        HistoryRecord(
                            id: "5000",
                            messages: nil,
                            messagesAdded: [HistoryMessageAdded(message: makeHistoryStub(id: "m-bad"))],
                            messagesDeleted: nil,
                            labelsAdded: nil,
                            labelsRemoved: nil
                        )
                    ],
                    nextPageToken: nil,
                    historyId: "2000"
                )
            )
        ])
        // Persistent transient error: every fetch attempt fails, exhausting retries.
        apiClient.getMessageErrors["m-bad"] = APIError.timeout

        let sut = makeOrchestrator()
        _ = try await sut.performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
        )

        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(
            historyId, Self.startingHistoryId,
            "A run with unfetched messages must not advance the cursor past them"
        )
        let consecutive = await failureTracker.consecutiveFailureCount
        XCTAssertEqual(consecutive, 1, "The failed run must count toward the escape threshold")
        let lastSuccess = await failureTracker.lastSuccessfulSyncTime
        XCTAssertNil(lastSuccess)
    }

    /// A message deleted server-side between the history record and the fetch
    /// has a terminal outcome (gone) — it must not freeze the cursor the way
    /// a real fetch failure does.
    @MainActor
    func testGoneMessageDoesNotFreezeCursor() async throws {
        apiClient.setHistoryResponsesByPageToken([
            (
                pageToken: nil,
                response: HistoryResponse(
                    history: [
                        HistoryRecord(
                            id: "5000",
                            messages: nil,
                            messagesAdded: [HistoryMessageAdded(message: makeHistoryStub(id: "m-gone"))],
                            messagesDeleted: nil,
                            labelsAdded: nil,
                            labelsRemoved: nil
                        )
                    ],
                    nextPageToken: nil,
                    historyId: "2000"
                )
            )
        ])
        apiClient.getMessageErrors["m-gone"] = APIError.notFound("m-gone")

        let sut = makeOrchestrator()
        _ = try await sut.performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
        )

        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, "2000", "A 404'd message is resolved, not a blocking failure")
        let consecutive = await failureTracker.consecutiveFailureCount
        XCTAssertEqual(consecutive, 0)
        XCTAssertGreaterThanOrEqual(
            apiClient.getMessageCallCount, 1,
            "Positive control: the message must actually have been requested"
        )
    }

    /// The core truthfulness contract: a message that FETCHES successfully
    /// but fails to PERSIST must freeze the cursor exactly like a fetch
    /// failure — previously it was counted successful and skipped forever.
    @MainActor
    func testPersistenceFailureFreezesCursor() async throws {
        apiClient.setHistoryResponsesByPageToken([
            (
                pageToken: nil,
                response: HistoryResponse(
                    history: [
                        HistoryRecord(
                            id: "5000",
                            messages: nil,
                            messagesAdded: [HistoryMessageAdded(message: makeHistoryStub(id: "m-new"))],
                            messagesDeleted: nil,
                            labelsAdded: nil,
                            labelsRemoved: nil
                        )
                    ],
                    nextPageToken: nil,
                    historyId: "2000"
                )
            )
        ])
        apiClient.getMessageResponses["m-new"] = makeFullMessage(id: "m-new")

        struct RoutingFailure: Error {}
        let sut = makeOrchestrator(conversationCreationError: RoutingFailure())
        _ = try await sut.performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
        )

        XCTAssertGreaterThanOrEqual(
            apiClient.getMessageCallCount, 1,
            "Positive control: the fetch must have succeeded before persistence failed"
        )
        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(
            historyId, Self.startingHistoryId,
            "A fetched-but-unpersisted message must freeze the cursor"
        )
        let consecutive = await failureTracker.consecutiveFailureCount
        XCTAssertEqual(consecutive, 1, "Persistence failures must count toward the escape threshold")
    }

    /// A deterministically malformed payload (no payload/headers) can never
    /// succeed on retry; treating it as a failure would freeze the cursor
    /// forever, so it must be recorded as unprocessable and released.
    @MainActor
    func testUnprocessableMessageDoesNotFreezeCursor() async throws {
        apiClient.setHistoryResponsesByPageToken([
            (
                pageToken: nil,
                response: HistoryResponse(
                    history: [
                        HistoryRecord(
                            id: "5000",
                            messages: nil,
                            messagesAdded: [HistoryMessageAdded(message: makeHistoryStub(id: "m-raw"))],
                            messagesDeleted: nil,
                            labelsAdded: nil,
                            labelsRemoved: nil
                        )
                    ],
                    nextPageToken: nil,
                    historyId: "2000"
                )
            )
        ])
        // Fetch succeeds but the payload is malformed (no payload/headers).
        apiClient.getMessageResponses["m-raw"] = makeHistoryStub(id: "m-raw")

        let sut = makeOrchestrator()
        _ = try await sut.performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
        )

        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, "2000", "Retrying a deterministically malformed payload can never succeed")
        let consecutive = await failureTracker.consecutiveFailureCount
        XCTAssertEqual(consecutive, 0)
        XCTAssertGreaterThanOrEqual(
            apiClient.getMessageCallCount, 1,
            "Positive control: the message must actually have been fetched and classified"
        )
    }

    @MainActor
    func testTruncatedHistoryFreezesCursorWithoutConsultingFailureTracker() async throws {
        apiClient.setHistoryResponsesByPageToken(makeOverflowingHistoryPages(pageCount: 50))
        for index in 0..<50 {
            apiClient.getMessageResponses["m\(index)"] = makeFullMessage(id: "m\(index)")
        }

        let sut = makeOrchestrator()
        _ = try await sut.performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
        )

        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(
            historyId, Self.startingHistoryId,
            "A truncated collection must retry from the same cursor next run"
        )
        // The truncation short-circuit skips the tracker entirely: the run is
        // neither a success (no timestamp) nor a failure (no strike).
        let consecutive = await failureTracker.consecutiveFailureCount
        XCTAssertEqual(consecutive, 0)
        let lastSuccess = await failureTracker.lastSuccessfulSyncTime
        XCTAssertNil(lastSuccess)
    }

    // MARK: - Fixture

    private func seedAccount() async throws {
        let context = coreDataStack.newBackgroundContext()
        await context.perform {
            _ = AccountBuilder()
                .withEmail(Self.myEmail)
                .withHistoryId(Self.startingHistoryId)
                .build(in: context)
        }
        try await coreDataStack.saveAsync(context: context)
    }

    @MainActor
    private func makeOrchestrator(conversationCreationError: Error? = nil) -> IncrementalSyncOrchestrator {
        let conversationManager: ConversationManager
        if let conversationCreationError {
            conversationManager = ConversationManager(
                findOrCreateConversationHandler: { _, _, _, _, _, _ in
                    throw conversationCreationError
                },
                currentUserEmail: { Self.myEmail }
            )
        } else {
            conversationManager = ConversationManager(
                currentUserEmail: { Self.myEmail }
            )
        }
        let messagePersister = MessagePersister(
            coreDataStack: coreDataStack,
            saveHTML: { _, _ in nil },
            conversationManager: conversationManager
        )
        let messageFetcher = MessageFetcher(apiClient: apiClient, clock: FakeSyncClock())
        return IncrementalSyncOrchestrator(
            messageFetcher: messageFetcher,
            messagePersister: messagePersister,
            historyProcessor: HistoryProcessor(coreDataStack: coreDataStack),
            conversationManager: conversationManager,
            dataCleanupService: DataCleanupService(
                coreDataStack: coreDataStack,
                conversationManager: conversationManager,
                migrationFlags: InMemoryMigrationFlagStore(),
                identityAliasProvider: { _ in [normalizedEmail(Self.myEmail)] }
            ),
            reconciliation: SyncReconciliation(
                messageFetcher: messageFetcher,
                failureTracker: failureTracker
            ),
            coreDataStack: coreDataStack,
            failureTracker: failureTracker
        )
    }

    /// Minimal message stub as it appears inside a history record (id + labels
    /// are all the collection phase reads).
    private func makeHistoryStub(id: String) -> GmailMessage {
        GmailMessage(
            id: id,
            threadId: "t-\(id)",
            labelIds: ["INBOX"],
            snippet: nil,
            historyId: nil,
            internalDate: nil,
            payload: nil,
            sizeEstimate: nil
        )
    }

    /// Full message for the fetch phase so the persister can store it.
    private func makeFullMessage(id: String) -> GmailMessage {
        GmailMessageBuilder()
            .withId(id)
            .withThreadId("t-\(id)")
            .withLabels(["INBOX"])
            .withFrom("alice@example.com", name: "Alice Smith")
            .withTo([Self.myEmail])
            .withSubject("Subject \(id)")
            .withSnippet("Snippet \(id)")
            .build()
    }

    /// 50 pages that all carry a nextPageToken, so the collection phase hits
    /// its page cap with more history remaining and reports truncation.
    private func makeOverflowingHistoryPages(pageCount: Int) -> [(pageToken: String?, response: HistoryResponse)] {
        (0..<pageCount).map { index in
            let requestPageToken: String? = index == 0 ? nil : "p\(index)"
            let record = HistoryRecord(
                id: "\(3000 + index)",
                messages: nil,
                messagesAdded: [HistoryMessageAdded(message: makeHistoryStub(id: "m\(index)"))],
                messagesDeleted: nil,
                labelsAdded: nil,
                labelsRemoved: nil
            )
            let response = HistoryResponse(
                history: [record],
                nextPageToken: "p\(index + 1)",
                historyId: "\(4000 + index)"
            )
            return (pageToken: requestPageToken, response: response)
        }
    }

    private func fetchAccountHistoryId() async -> String? {
        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            let request = Account.fetchRequest()
            request.fetchLimit = 1
            request.includesPendingChanges = false
            return (try? context.fetch(request).first)?.historyId
        }
    }
}
