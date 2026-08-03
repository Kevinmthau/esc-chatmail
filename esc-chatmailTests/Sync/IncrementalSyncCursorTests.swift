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

    // MARK: - Durable ledger scenarios

    /// The durable-deferral contract: a held run commits the failing IDs as
    /// deferred ledger rows in the SAME save that keeps the cursor frozen — a
    /// crash after the run leaves the tracked set durable, not in UserDefaults.
    @MainActor
    func testFailingRunCommitsDeferredLedgerRowsWithFrozenCursor() async throws {
        apiClient.setHistoryResponsesByPageToken(makeSinglePageHistory(messageId: "m-bad"))
        apiClient.getMessageErrors["m-bad"] = APIError.timeout

        let sut = makeOrchestrator()
        _ = try await sut.performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
        )

        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, Self.startingHistoryId)

        let rows = await fetchLedgerRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.gmailMessageId, "m-bad")
        XCTAssertEqual(rows.first?.state, AbandonedSyncMessage.State.deferred.rawValue)
        XCTAssertEqual(rows.first?.failureClass, AbandonedSyncMessage.FailureClass.fetchFailed.rawValue)
        XCTAssertEqual(
            rows.first?.sourceHistoryId, Self.startingHistoryId,
            "The row must record the frozen cursor position that produced it"
        )
    }

    /// The escape hatch's atomicity contract: at the threshold, the cursor
    /// advance and the deferred→abandoned transition commit in one save, and
    /// the counters reset only afterwards.
    @MainActor
    func testEscapeHatchCommitsAbandonmentWithAdvancedCursor() async throws {
        defaults.set(
            SyncConfig.maxConsecutiveSyncFailures - 1,
            forKey: SyncConfig.consecutiveFailuresKey
        )
        apiClient.setHistoryResponsesByPageToken(makeSinglePageHistory(messageId: "m-stuck"))
        apiClient.getMessageErrors["m-stuck"] = APIError.timeout

        let abandonedNotification = expectation(forNotification: .syncMessagesAbandoned, object: nil) { note in
            (note.userInfo?["count"] as? Int) == 1
        }

        let sut = makeOrchestrator()
        _ = try await sut.performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
        )

        await fulfillment(of: [abandonedNotification], timeout: 5)

        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, "2000", "The escape hatch must advance at the threshold")
        let rows = await fetchLedgerRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.gmailMessageId, "m-stuck")
        XCTAssertEqual(
            rows.first?.state, AbandonedSyncMessage.State.abandoned.rawValue,
            "The skipped ID must be durably abandoned in the same run that advanced past it"
        )
        let consecutive = await failureTracker.consecutiveFailureCount
        XCTAssertEqual(consecutive, 0)
    }

    /// Deferred rows from an earlier failing run are removed by the next clean
    /// run — the frozen-cursor re-scan recovered their messages.
    @MainActor
    func testCleanRunClearsPreviouslyDeferredRows() async throws {
        try await seedLedgerRow(id: "previously-failing", state: .deferred)
        defaults.set(1, forKey: SyncConfig.consecutiveFailuresKey)
        apiClient.setHistoryResponsesByPageToken(makeSinglePageHistory(messageId: "m-new"))
        apiClient.getMessageResponses["m-new"] = makeFullMessage(id: "m-new")

        let sut = makeOrchestrator()
        _ = try await sut.performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
        )

        let rows = await fetchLedgerRows()
        XCTAssertTrue(rows.isEmpty, "A clean run must clear recovered deferred rows")
        let consecutive = await failureTracker.consecutiveFailureCount
        XCTAssertEqual(consecutive, 0)
        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, "2000")
    }

    /// The drain must skip deferred rows: their messages are retried by the
    /// normal re-scan of the frozen window, and a drain fetch would both
    /// double-fetch them and burn their retry budget before abandonment.
    @MainActor
    func testDrainSkipsDeferredRows() async throws {
        try await seedLedgerRow(id: "deferred-not-drained", state: .deferred)
        apiClient.setHistoryResponsesByPageToken(makeSinglePageHistory(messageId: "m-new"))
        apiClient.getMessageResponses["m-new"] = makeFullMessage(id: "m-new")

        let sut = makeOrchestrator()
        _ = try await sut.performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
        )

        XCTAssertFalse(
            apiClient.getMessageCalledIds.contains("deferred-not-drained"),
            "The drain must not fetch rows that are still covered by the frozen cursor"
        )
        XCTAssertGreaterThanOrEqual(
            apiClient.getMessageCallCount, 1,
            "Positive control: the run did fetch the history message"
        )
    }

    /// Drain resolution is atomic with the recovered message: the ledger row's
    /// deletion and the persisted Message row commit in the same final save.
    @MainActor
    func testDrainRecoveryCommitsRowDeletionWithPersistedMessage() async throws {
        try await seedLedgerRow(id: "was-abandoned", state: .abandoned)
        apiClient.setHistoryResponsesByPageToken(makeSinglePageHistory(messageId: "m-new"))
        apiClient.getMessageResponses["m-new"] = makeFullMessage(id: "m-new")
        apiClient.getMessageResponses["was-abandoned"] = makeFullMessage(id: "was-abandoned")

        let sut = makeOrchestrator()
        _ = try await sut.performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
        )

        let rows = await fetchLedgerRows()
        XCTAssertTrue(rows.isEmpty, "A recovered abandoned row must leave the ledger")
        let recovered = await messageExists(id: "was-abandoned")
        XCTAssertTrue(recovered, "The recovered message must be durably persisted")
    }

    // MARK: - History-recovery scenarios

    /// A clean recovery run advances the cursor to the profile's historyId,
    /// clears previously deferred rows (the re-scan recovered them), and
    /// resets the failure counter — success state committed only after the
    /// recovery's durable save.
    @MainActor
    func testCleanRecoveryAdvancesCursorAndCommitsSuccess() async throws {
        try await seedLedgerRow(id: "previously-failing", state: .deferred)
        defaults.set(1, forKey: SyncConfig.consecutiveFailuresKey)

        apiClient.listHistoryError = APIError.historyIdExpired
        apiClient.listMessagesResponse = MessagesListResponse(
            messages: [MessageListItem(id: "m-rec", threadId: "t-m-rec")],
            nextPageToken: nil,
            resultSizeEstimate: 1
        )
        apiClient.getMessageResponses["m-rec"] = makeFullMessage(id: "m-rec")
        apiClient.profileResponse = GmailProfile(
            emailAddress: Self.myEmail,
            messagesTotal: 1,
            threadsTotal: 1,
            historyId: "7777"
        )

        let sut = makeOrchestrator()
        let result = try await sut.performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
        )

        XCTAssertTrue(result.hadWarnings, "Recovery runs report warnings")
        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, "7777", "A clean recovery advances to the profile historyId")
        let recovered = await messageExists(id: "m-rec")
        XCTAssertTrue(recovered)
        let rows = await fetchLedgerRows()
        XCTAssertTrue(rows.isEmpty, "A clean recovery clears recovered deferred rows")
        let consecutive = await failureTracker.consecutiveFailureCount
        XCTAssertEqual(consecutive, 0, "Recovery success must reset the counter after the save")
        let lastSuccess = await failureTracker.lastSuccessfulSyncTime
        XCTAssertNotNil(lastSuccess)
    }

    /// A recovery run with fetch failures freezes the cursor at its prior
    /// value and commits the failing IDs as durable deferred rows in the same
    /// save — no success state leaks.
    @MainActor
    func testFailingRecoveryFreezesCursorAndCommitsDeferredRows() async throws {
        apiClient.listHistoryError = APIError.historyIdExpired
        apiClient.listMessagesResponse = MessagesListResponse(
            messages: [MessageListItem(id: "m-rec-bad", threadId: "t-m-rec-bad")],
            nextPageToken: nil,
            resultSizeEstimate: 1
        )
        // Persistent per-id transient error: every attempt fails, exhausting retries.
        apiClient.getMessageErrors["m-rec-bad"] = APIError.timeout
        apiClient.profileResponse = GmailProfile(
            emailAddress: Self.myEmail,
            messagesTotal: 1,
            threadsTotal: 1,
            historyId: "7777"
        )

        let sut = makeOrchestrator()
        _ = try await sut.performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
        )

        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(
            historyId, Self.startingHistoryId,
            "A recovery with unfetched messages must not advance the cursor past them"
        )
        let rows = await fetchLedgerRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.gmailMessageId, "m-rec-bad")
        XCTAssertEqual(rows.first?.state, AbandonedSyncMessage.State.deferred.rawValue)
        XCTAssertEqual(rows.first?.failureClass, AbandonedSyncMessage.FailureClass.fetchFailed.rawValue)
        XCTAssertNil(rows.first?.sourceHistoryId, "The expired cursor is not a meaningful source position")
        let consecutive = await failureTracker.consecutiveFailureCount
        XCTAssertEqual(consecutive, 1, "The failed recovery must count toward the escape threshold")
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

    /// One history page delivering a single new message and latestHistoryId "2000".
    private func makeSinglePageHistory(messageId: String) -> [(pageToken: String?, response: HistoryResponse)] {
        [
            (
                pageToken: nil,
                response: HistoryResponse(
                    history: [
                        HistoryRecord(
                            id: "5000",
                            messages: nil,
                            messagesAdded: [HistoryMessageAdded(message: makeHistoryStub(id: messageId))],
                            messagesDeleted: nil,
                            labelsAdded: nil,
                            labelsRemoved: nil
                        )
                    ],
                    nextPageToken: nil,
                    historyId: "2000"
                )
            )
        ]
    }

    private struct LedgerRow {
        let gmailMessageId: String?
        let state: String?
        let failureClass: String?
        let sourceHistoryId: String?
    }

    private func seedLedgerRow(id: String, state: AbandonedSyncMessage.State) async throws {
        let context = coreDataStack.newBackgroundContext()
        try await context.perform {
            let record = AbandonedSyncMessage(context: context)
            record.setValue(UUID(), forKey: "id")
            record.setValue(id, forKey: "gmailMessageId")
            record.setValue(Date(timeIntervalSinceNow: -3600), forKey: "abandonedAt")
            record.setValue(Int16(0), forKey: "retryCount")
            record.setValue(state.rawValue, forKey: "state")
            try context.save()
        }
    }

    private func fetchLedgerRows() async -> [LedgerRow] {
        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: "AbandonedSyncMessage")
            request.includesPendingChanges = false
            let records = (try? context.fetch(request)) ?? []
            return records.map {
                LedgerRow(
                    gmailMessageId: $0.value(forKey: "gmailMessageId") as? String,
                    state: $0.value(forKey: "state") as? String,
                    failureClass: $0.value(forKey: "failureClass") as? String,
                    sourceHistoryId: $0.value(forKey: "sourceHistoryId") as? String
                )
            }
        }
    }

    private func messageExists(id: String) async -> Bool {
        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            let request = Message.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id)
            request.includesPendingChanges = false
            return ((try? context.count(for: request)) ?? 0) > 0
        }
    }
}
