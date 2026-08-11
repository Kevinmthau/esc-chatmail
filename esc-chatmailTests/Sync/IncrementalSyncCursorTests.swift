import XCTest
import CoreData
@testable import esc_chatmail

/// End-to-end coverage of incremental sync's durable history executor:
///
/// - a clean run advances the cursor to Gmail's latest historyId,
/// - fetch failures freeze the cursor (below the 3-strikes threshold),
/// - bounded history slices resume from model-v3 checkpoints across fresh
///   orchestrators, and
/// - the strike count commits in a dedicated model-v3 counter row with the
///   deferred ledger and cursor/progress transition.
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
        XCTAssertFalse(result.needsFollowUp)
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
        let result = try await sut.performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
        )

        XCTAssertTrue(result.needsFollowUp)
        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(
            historyId, Self.startingHistoryId,
            "A run with unfetched messages must not advance the cursor past them"
        )
        let checkpoint = try await fetchHistoryCheckpoint()
        XCTAssertNil(checkpoint, "The first history slice retries from the frozen cursor")
        let durableFailureCount = try await fetchFailureCounter()
        XCTAssertEqual(durableFailureCount, 1)
        let legacyConsecutive = await failureTracker.consecutiveFailureCount
        XCTAssertEqual(legacyConsecutive, 0, "Production strikes must not live in UserDefaults")
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
        let checkpoint = try await fetchHistoryCheckpoint()
        XCTAssertNil(checkpoint)
        let durableFailureCount = try await fetchFailureCounter()
        XCTAssertEqual(durableFailureCount, 1)
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
    func testCheckpointedHistoryResumesAcrossFreshOrchestrators() async throws {
        apiClient.setHistoryResponsesByPageToken(makeHistoryPages(pageCount: 3))
        for index in 0..<3 {
            apiClient.getMessageResponses["m\(index)"] = makeFullMessage(id: "m\(index)")
        }

        let first = makeOrchestrator(historyPageLimit: 2)
        let firstResult = try await first.performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
        )

        XCTAssertTrue(firstResult.hadWarnings, "A continuation is incomplete, not terminal success")
        XCTAssertTrue(firstResult.needsFollowUp)
        let firstHistoryId = await fetchAccountHistoryId()
        XCTAssertEqual(firstHistoryId, Self.startingHistoryId)
        let firstCheckpoint = try await fetchHistoryCheckpoint()
        XCTAssertEqual(firstCheckpoint?.pageToken, "p2")
        let firstDurableFailureCount = try await fetchFailureCounter()
        XCTAssertEqual(firstDurableFailureCount, 0)
        XCTAssertEqual(apiClient.listHistoryCalls.map(\.pageToken), [nil, "p1"])
        let firstLastSuccess = await failureTracker.lastSuccessfulSyncTime
        XCTAssertNil(firstLastSuccess)

        // Simulate a process-style restart of every in-memory executor/tracker
        // object. Core Data is the only progress source that survives.
        failureTracker = SyncFailureTracker(defaults: defaults, coreDataStack: coreDataStack)
        let second = makeOrchestrator(historyPageLimit: 2)
        let secondResult = try await second.performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
        )

        XCTAssertFalse(secondResult.hadWarnings)
        XCTAssertFalse(secondResult.needsFollowUp)
        let terminalHistoryId = await fetchAccountHistoryId()
        XCTAssertEqual(terminalHistoryId, "4002")
        let terminalCheckpoint = try await fetchHistoryCheckpoint()
        XCTAssertNil(terminalCheckpoint)
        XCTAssertEqual(apiClient.listHistoryCalls.map(\.pageToken), [nil, "p1", "p2"])
        let savedMessage0 = await messageExists(id: "m0")
        let savedMessage1 = await messageExists(id: "m1")
        let savedMessage2 = await messageExists(id: "m2")
        XCTAssertTrue(savedMessage0)
        XCTAssertTrue(savedMessage1)
        XCTAssertTrue(savedMessage2)
        let terminalLastSuccess = await failureTracker.lastSuccessfulSyncTime
        XCTAssertNotNil(terminalLastSuccess)
    }

    @MainActor
    func testFiftyOneHistoryPagesCompleteAcrossFreshOrchestrators() async throws {
        let pageCount = 51
        apiClient.setHistoryResponsesByPageToken(makeHistoryPages(pageCount: pageCount))
        for index in 0..<pageCount {
            apiClient.getMessageResponses["m\(index)"] = makeFullMessage(id: "m\(index)")
        }

        for sliceIndex in 0..<5 {
            failureTracker = SyncFailureTracker(defaults: defaults, coreDataStack: coreDataStack)
            let result = try await makeOrchestrator().performSync(
                progressHandler: { _, _ in },
                initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
            )

            XCTAssertTrue(result.hadWarnings)
            let frozenHistoryId = await fetchAccountHistoryId()
            XCTAssertEqual(frozenHistoryId, Self.startingHistoryId)
            let checkpoint = try await fetchHistoryCheckpoint()
            XCTAssertEqual(checkpoint?.pageToken, "p\((sliceIndex + 1) * 10)")
            let durableFailureCount = try await fetchFailureCounter()
            XCTAssertEqual(durableFailureCount, 0)
        }

        failureTracker = SyncFailureTracker(defaults: defaults, coreDataStack: coreDataStack)
        let terminalResult = try await makeOrchestrator().performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
        )

        XCTAssertFalse(terminalResult.hadWarnings)
        let terminalHistoryId = await fetchAccountHistoryId()
        XCTAssertEqual(terminalHistoryId, "4050")
        let terminalCheckpoint = try await fetchHistoryCheckpoint()
        XCTAssertNil(terminalCheckpoint)
        XCTAssertEqual(apiClient.listHistoryCalls.count, pageCount)
        XCTAssertEqual(
            [0, 10, 20, 30, 40, 50].map { apiClient.listHistoryCalls[$0].pageToken },
            [nil, "p10", "p20", "p30", "p40", "p50"]
        )
        let lastPageMessageExists = await messageExists(id: "m50")
        XCTAssertTrue(lastPageMessageExists, "The page beyond the former 50-page cap must be durable")
    }

    @MainActor
    func testRejectedStoredPageTokenReplaysExactlyOnceFromFrozenCursor() async throws {
        try await seedHistoryCheckpoint(pageToken: "stale-token")
        try await seedFailureCounter(1)
        apiClient.listHistoryErrorsByPageToken["stale-token"] = APIError.invalidHistoryPageToken
        apiClient.setHistoryResponsesByPageToken([
            (
                pageToken: nil,
                response: HistoryResponse(
                    history: [],
                    nextPageToken: nil,
                    historyId: "2000"
                )
            )
        ])

        _ = try await makeOrchestrator().performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
        )

        XCTAssertEqual(apiClient.listHistoryCalls.map(\.pageToken), ["stale-token", nil])
        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, "2000")
        let checkpoint = try await fetchHistoryCheckpoint()
        XCTAssertNil(checkpoint)
    }

    @MainActor
    func testRepeatedInvalidPageTokenStopsAfterOneReplay() async throws {
        try await seedHistoryCheckpoint(pageToken: "stale-token")
        try await seedFailureCounter(1)
        apiClient.listHistoryErrorsByPageToken["stale-token"] = APIError.invalidHistoryPageToken
        // The stored-token request consumes the keyed error first; the one
        // allowed replay from nil then consumes this global error.
        apiClient.listHistoryError = APIError.invalidHistoryPageToken

        do {
            _ = try await makeOrchestrator().performSync(
                progressHandler: { _, _ in },
                initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
            )
            XCTFail("The failed replay must propagate")
        } catch APIError.invalidHistoryPageToken {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(apiClient.listHistoryCalls.map(\.pageToken), ["stale-token", nil])
        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, Self.startingHistoryId)
        let checkpoint = try await fetchHistoryCheckpoint()
        XCTAssertNil(checkpoint, "The rejected persisted token is durably discarded before replay")
        let durableFailureCount = try await fetchFailureCounter()
        XCTAssertEqual(durableFailureCount, 1)
    }

    @MainActor
    func testUnrelatedInvalidDataOnStoredTokenDoesNotReplay() async throws {
        try await seedHistoryCheckpoint(pageToken: "stored-token")
        try await seedFailureCounter(1)
        apiClient.listHistoryErrorsByPageToken["stored-token"] = APIError.invalidData(
            "unrelated invalid request"
        )

        do {
            _ = try await makeOrchestrator().performSync(
                progressHandler: { _, _ in },
                initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
            )
            XCTFail("Unrelated invalidData must abort")
        } catch let APIError.invalidData(message) {
            XCTAssertTrue(message.contains("unrelated"))
        }

        XCTAssertEqual(apiClient.listHistoryCalls.map(\.pageToken), ["stored-token"])
        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, Self.startingHistoryId)
        let checkpoint = try await fetchHistoryCheckpoint()
        XCTAssertEqual(checkpoint?.pageToken, "stored-token")
        let durableFailureCount = try await fetchFailureCounter()
        XCTAssertEqual(durableFailureCount, 1)
    }

    @MainActor
    func testAuthenticatedAccountMismatchAbortsBeforeAnyGmailRequest() async throws {
        let sut = makeOrchestrator(authenticatedAccountEmail: { "other@example.com" })

        do {
            _ = try await sut.performSync(
                progressHandler: { _, _ in },
                initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
            )
            XCTFail("Cross-account sync must abort")
        } catch let error as IncrementalSyncAccountError {
            guard case .authenticatedAccountMismatch = error else {
                return XCTFail("Unexpected account error: \(error)")
            }
        }

        XCTAssertEqual(apiClient.listHistoryCallCount, 0)
        XCTAssertEqual(apiClient.getMessageCallCount, 0)
    }

    @MainActor
    func testAuthenticatedAccountMismatchWithNilCursorAbortsBeforeInitialFallback() async throws {
        try await setAccountHistoryId(nil)
        let fallbackCalled = LockedFlag()
        let sut = makeOrchestrator(authenticatedAccountEmail: { "other@example.com" })

        do {
            _ = try await sut.performSync(
                progressHandler: { _, _ in },
                initialSyncFallback: { fallbackCalled.set() }
            )
            XCTFail("A surviving row for another account must not trigger initial sync")
        } catch let error as IncrementalSyncAccountError {
            guard case .authenticatedAccountMismatch = error else {
                return XCTFail("Unexpected account error: \(error)")
            }
        }

        XCTAssertFalse(fallbackCalled.value)
        XCTAssertEqual(apiClient.listHistoryCallCount, 0)
        XCTAssertEqual(apiClient.getMessageCallCount, 0)
    }

    @MainActor
    func testInitialSyncFallbackWithoutDurableHistoryRequestsImmediateFollowUp() async throws {
        try await setAccountHistoryId(nil)
        let sut = makeOrchestrator()

        let result = try await sut.performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: {}
        )

        XCTAssertTrue(result.hadWarnings)
        XCTAssertTrue(
            result.needsFollowUp,
            "An incomplete initial fallback must retain prompt-retry intent"
        )
    }

    @MainActor
    func testInitialSyncFallbackWithDurableHistoryCompletesCleanly() async throws {
        try await setAccountHistoryId(nil)
        let sut = makeOrchestrator()

        let result = try await sut.performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: {
                try await self.setAccountHistoryId("fresh-history")
            }
        )

        XCTAssertFalse(result.hadWarnings)
        XCTAssertFalse(result.needsFollowUp)
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
        let checkpoint = try await fetchHistoryCheckpoint()
        XCTAssertNil(checkpoint)
        let durableFailureCount = try await fetchFailureCounter()
        XCTAssertEqual(durableFailureCount, 1)
    }

    /// PR #143's accepted gap, closed by the makeSyncContext seam: through a
    /// REAL orchestrator run, a failed final save must commit nothing — the
    /// cursor stays at its stored value and the tracker's success state is
    /// untouched, because `commit(plan)` only runs after a successful save.
    /// The deletion record forces the atomic (no-intermediate-saves) mode so
    /// the final save is the run's only save attempt.
    @MainActor
    func testFailedFinalSaveLeavesCursorAndTrackerSuccessStateUntouched() async throws {
        apiClient.setHistoryResponsesByPageToken([
            (
                pageToken: nil,
                response: HistoryResponse(
                    history: [
                        HistoryRecord(
                            id: "5000",
                            messages: nil,
                            messagesAdded: nil,
                            messagesDeleted: [
                                HistoryMessageDeleted(
                                    message: MessageListItem(id: "m-unknown", threadId: "t-unknown")
                                )
                            ],
                            labelsAdded: nil,
                            labelsRemoved: nil
                        )
                    ],
                    nextPageToken: nil,
                    historyId: "2000"
                )
            )
        ])
        let failingContext = makeFailingSaveContext()
        // Pin the atomic-mode premise itself: the failing save must be the
        // FINAL save — the only one carrying the staged cursor. If the
        // deletion policy ever stops forcing whole-run atomicity, an earlier
        // intermediate save (no Account change staged) would fail first and
        // this flag stays false.
        let sawStagedCursorAtSaveTime = LockedFlag()
        failingContext.onSaveAttempt = { [weak failingContext] _ in
            guard let failingContext else { return }
            let staged = failingContext.updatedObjects.contains { object in
                (object as? Account)?.changedValues().keys.contains("historyId") == true
            }
            if staged {
                sawStagedCursorAtSaveTime.set()
            }
        }

        let sut = makeOrchestrator(makeSyncContext: { failingContext })
        do {
            _ = try await sut.performSync(
                progressHandler: { _, _ in },
                initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
            )
            XCTFail("A failed final save must abort the run")
        } catch {
            // Expected: the scripted save failure surfaces as a thrown error.
        }

        XCTAssertGreaterThanOrEqual(failingContext.saveAttempts, 1, "Positive control: the final save must have been attempted")
        XCTAssertTrue(
            sawStagedCursorAtSaveTime.value,
            "The failing save must be the final save — the one carrying the staged cursor"
        )
        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(
            historyId, Self.startingHistoryId,
            "A cursor staged into a context whose save failed must not reach the store"
        )
        let lastSuccess = await failureTracker.lastSuccessfulSyncTime
        XCTAssertNil(lastSuccess, "commit(plan) must not run after a failed save")
        let consecutive = await failureTracker.consecutiveFailureCount
        XCTAssertEqual(consecutive, 0, "A clean run records no failure even when its save fails")
        let failedSaveCheckpoint = try await fetchHistoryCheckpoint()
        XCTAssertNil(failedSaveCheckpoint)
    }

    /// The failure-side mirror of testFailingRunCommitsDeferredLedgerRowsWithFrozenCursor:
    /// when the final save fails, the staged deferred rows die with the
    /// context (nothing reaches the store), including its checkpointed strike.
    @MainActor
    func testFailedFinalSaveDiscardsStagedDeferredRows() async throws {
        apiClient.setHistoryResponsesByPageToken([
            (
                pageToken: nil,
                response: HistoryResponse(
                    history: [
                        HistoryRecord(
                            id: "5000",
                            messages: nil,
                            messagesAdded: [HistoryMessageAdded(message: makeHistoryStub(id: "m-bad"))],
                            messagesDeleted: [
                                HistoryMessageDeleted(
                                    message: MessageListItem(id: "m-unknown", threadId: "t-unknown")
                                )
                            ],
                            labelsAdded: nil,
                            labelsRemoved: nil
                        )
                    ],
                    nextPageToken: nil,
                    historyId: "2000"
                )
            )
        ])
        apiClient.getMessageErrors["m-bad"] = APIError.timeout
        let failingContext = makeFailingSaveContext()

        let sut = makeOrchestrator(makeSyncContext: { failingContext })
        do {
            _ = try await sut.performSync(
                progressHandler: { _, _ in },
                initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
            )
            XCTFail("A failed final save must abort the run")
        } catch {
            // Expected: the scripted save failure surfaces as a thrown error.
        }

        XCTAssertGreaterThanOrEqual(failingContext.saveAttempts, 1, "Positive control: the final save must have been attempted")
        let rows = await fetchLedgerRows()
        XCTAssertTrue(
            rows.isEmpty,
            "Deferred rows staged into a failed save must die with the context"
        )
        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, Self.startingHistoryId)
        let consecutive = await failureTracker.consecutiveFailureCount
        XCTAssertEqual(
            consecutive, 0,
            "The retired UserDefaults counter must not change before a failed save"
        )
        let failedStrikeCheckpoint = try await fetchHistoryCheckpoint()
        XCTAssertNil(failedStrikeCheckpoint)
        let failedDurableFailureCount = try await fetchFailureCounter()
        XCTAssertNil(failedDurableFailureCount, "The durable strike dies with the failed save")
        let lastSuccess = await failureTracker.lastSuccessfulSyncTime
        XCTAssertNil(lastSuccess)
    }

    @MainActor
    func testFailedContinuationSaveRetainsPriorTokenCounterAndCursor() async throws {
        try await seedHistoryCheckpoint(pageToken: "p-old")
        try await seedFailureCounter(2)
        apiClient.setHistoryResponsesByPageToken([
            (
                pageToken: "p-old",
                response: makeDeletionHistoryResponse(
                    nextPageToken: "p-new",
                    historyId: "2000"
                )
            )
        ])
        let failingContext = makeFailingSaveContext()

        do {
            _ = try await makeOrchestrator(makeSyncContext: { failingContext }).performSync(
                progressHandler: { _, _ in },
                initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
            )
            XCTFail("Expected the final save to fail")
        } catch {
            // Expected.
        }

        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, Self.startingHistoryId)
        let checkpoint = try await fetchHistoryCheckpoint()
        XCTAssertEqual(checkpoint?.pageToken, "p-old")
        let durableFailureCount = try await fetchFailureCounter()
        XCTAssertEqual(durableFailureCount, 2)
    }

    @MainActor
    func testFailedTerminalSaveRetainsPriorTokenCounterAndCursor() async throws {
        try await seedHistoryCheckpoint(pageToken: "p-old")
        try await seedFailureCounter(2)
        apiClient.setHistoryResponsesByPageToken([
            (
                pageToken: "p-old",
                response: makeDeletionHistoryResponse(
                    nextPageToken: nil,
                    historyId: "2000"
                )
            )
        ])
        let failingContext = makeFailingSaveContext()

        do {
            _ = try await makeOrchestrator(makeSyncContext: { failingContext }).performSync(
                progressHandler: { _, _ in },
                initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
            )
            XCTFail("Expected the final save to fail")
        } catch {
            // Expected.
        }

        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, Self.startingHistoryId)
        let checkpoint = try await fetchHistoryCheckpoint()
        XCTAssertEqual(checkpoint?.pageToken, "p-old")
        let durableFailureCount = try await fetchFailureCounter()
        XCTAssertEqual(durableFailureCount, 2)
    }

    @MainActor
    func testFailedSaveKeepsLegacyCounterAvailableForMigrationRetry() async throws {
        defaults.set(
            SyncConfig.maxConsecutiveSyncFailures - 1,
            forKey: SyncConfig.consecutiveFailuresKey
        )
        apiClient.setHistoryResponsesByPageToken([
            (
                pageToken: nil,
                response: HistoryResponse(
                    history: [
                        HistoryRecord(
                            id: "5000",
                            messages: nil,
                            messagesAdded: [HistoryMessageAdded(message: makeHistoryStub(id: "m-bad"))],
                            messagesDeleted: [
                                HistoryMessageDeleted(
                                    message: MessageListItem(id: "m-unknown", threadId: "t-unknown")
                                )
                            ],
                            labelsAdded: nil,
                            labelsRemoved: nil
                        )
                    ],
                    nextPageToken: nil,
                    historyId: "2000"
                )
            )
        ])
        apiClient.getMessageErrors["m-bad"] = APIError.timeout
        let failingContext = makeFailingSaveContext()

        do {
            _ = try await makeOrchestrator(makeSyncContext: { failingContext }).performSync(
                progressHandler: { _, _ in },
                initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
            )
            XCTFail("Expected the final save to fail")
        } catch {
            // Expected.
        }

        XCTAssertEqual(
            defaults.integer(forKey: SyncConfig.consecutiveFailuresKey),
            SyncConfig.maxConsecutiveSyncFailures - 1
        )
        let durableFailureCount = try await fetchFailureCounter()
        XCTAssertNil(durableFailureCount, "The unsaved migration row must roll back")
        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, Self.startingHistoryId)
        let ledgerRows = await fetchLedgerRows()
        XCTAssertTrue(ledgerRows.isEmpty)
    }

    @MainActor
    func testCancellationDuringMessageFetchRetainsCheckpointAndFreshRunResumes() async throws {
        try await seedHistoryCheckpoint(pageToken: "p-old")
        try await seedFailureCounter(1)
        apiClient.setHistoryResponsesByPageToken([
            (
                pageToken: "p-old",
                response: HistoryResponse(
                    history: [
                        HistoryRecord(
                            id: "5000",
                            messages: nil,
                            messagesAdded: [HistoryMessageAdded(message: makeHistoryStub(id: "m-slow"))],
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
        apiClient.getMessageResponses["m-slow"] = makeFullMessage(id: "m-slow")
        apiClient.artificialDelay = 0.25

        let task = Task {
            try await makeOrchestrator().performSync(
                progressHandler: { _, _ in },
                initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
            )
        }
        for _ in 0..<100 where apiClient.getMessageCallCountSnapshot() == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(
            apiClient.getMessageCallCountSnapshot(),
            0,
            "The cancellation must occur during message fan-out"
        )
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        var checkpoint = try await fetchHistoryCheckpoint()
        XCTAssertEqual(checkpoint?.pageToken, "p-old")
        var durableFailureCount = try await fetchFailureCounter()
        XCTAssertEqual(durableFailureCount, 1)
        var historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, Self.startingHistoryId)

        apiClient.artificialDelay = 0
        failureTracker = SyncFailureTracker(defaults: defaults, coreDataStack: coreDataStack)
        _ = try await makeOrchestrator().performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
        )

        XCTAssertEqual(apiClient.listHistoryCalls.last?.pageToken, "p-old")
        checkpoint = try await fetchHistoryCheckpoint()
        XCTAssertNil(checkpoint)
        durableFailureCount = try await fetchFailureCounter()
        XCTAssertEqual(durableFailureCount, 0)
        historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, "2000")
    }

    /// The escape hatch's atomicity contract: at the threshold, the cursor
    /// advance and the deferred→abandoned transition commit in one save, and
    /// the counters reset only afterwards.
    @MainActor
    func testEscapeHatchCommitsAbandonmentWithAdvancedCursor() async throws {
        try await seedFailureCounter(SyncConfig.maxConsecutiveSyncFailures - 1)
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
        let escapedCheckpoint = try await fetchHistoryCheckpoint()
        XCTAssertNil(escapedCheckpoint)
        let escapedFailureCount = try await fetchFailureCounter()
        XCTAssertEqual(escapedFailureCount, 0)
    }

    @MainActor
    func testFailureCounterSurvivesFreshTrackersAndAdvancesOnlyAtThreshold() async throws {
        apiClient.setHistoryResponsesByPageToken(makeSinglePageHistory(messageId: "m-stuck"))
        apiClient.getMessageErrors["m-stuck"] = APIError.timeout
        for expectedCount in 1..<SyncConfig.maxConsecutiveSyncFailures {
            failureTracker = SyncFailureTracker(defaults: defaults, coreDataStack: coreDataStack)
            _ = try await makeOrchestrator().performSync(
                progressHandler: { _, _ in },
                initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
            )

            let checkpoint = try await fetchHistoryCheckpoint()
            XCTAssertNil(checkpoint)
            let durableFailureCount = try await fetchFailureCounter()
            XCTAssertEqual(durableFailureCount, expectedCount)
            let historyId = await fetchAccountHistoryId()
            XCTAssertEqual(historyId, Self.startingHistoryId)
            let legacyCount = await failureTracker.consecutiveFailureCount
            XCTAssertEqual(legacyCount, 0, "The pre-v3 counter is retired after the first durable save")
        }

        let abandonedNotification = expectation(
            forNotification: .syncMessagesAbandoned,
            object: nil
        ) { note in
            (note.userInfo?["count"] as? Int) == 1
        }
        failureTracker = SyncFailureTracker(defaults: defaults, coreDataStack: coreDataStack)
        _ = try await makeOrchestrator().performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
        )
        await fulfillment(of: [abandonedNotification], timeout: 5)

        let terminalHistoryId = await fetchAccountHistoryId()
        XCTAssertEqual(terminalHistoryId, "2000")
        let terminalCheckpoint = try await fetchHistoryCheckpoint()
        XCTAssertNil(terminalCheckpoint)
        let terminalFailureCount = try await fetchFailureCounter()
        XCTAssertEqual(terminalFailureCount, 0)
        let rows = await fetchLedgerRows()
        XCTAssertEqual(rows.first?.state, AbandonedSyncMessage.State.abandoned.rawValue)
    }

    @MainActor
    func testLegacyCounterImportsOnceAndParticipatesInAtomicEscape() async throws {
        defaults.set(
            SyncConfig.maxConsecutiveSyncFailures - 1,
            forKey: SyncConfig.consecutiveFailuresKey
        )
        apiClient.setHistoryResponsesByPageToken(makeSinglePageHistory(messageId: "m-legacy-stuck"))
        apiClient.getMessageErrors["m-legacy-stuck"] = APIError.timeout

        let abandonedNotification = expectation(
            forNotification: .syncMessagesAbandoned,
            object: nil
        ) { note in
            (note.userInfo?["count"] as? Int) == 1
        }
        _ = try await makeOrchestrator().performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
        )
        await fulfillment(of: [abandonedNotification], timeout: 5)

        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, "2000")
        let durableFailureCount = try await fetchFailureCounter()
        XCTAssertEqual(durableFailureCount, 0)
        XCTAssertNil(
            defaults.object(forKey: SyncConfig.consecutiveFailuresKey),
            "Legacy state is removed only after the durable counter transaction saves"
        )
        let rows = await fetchLedgerRows()
        XCTAssertEqual(rows.first?.state, AbandonedSyncMessage.State.abandoned.rawValue)
    }

    /// Deferred rows from an earlier failing run are removed by the next clean
    /// run — the frozen-cursor re-scan recovered their messages.
    @MainActor
    func testCleanRunClearsPreviouslyDeferredRows() async throws {
        try await seedLedgerRow(id: "previously-failing", state: .deferred)
        try await seedFailureCounter(1)
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
        let cleanCheckpoint = try await fetchHistoryCheckpoint()
        XCTAssertNil(cleanCheckpoint)
        let cleanFailureCount = try await fetchFailureCounter()
        XCTAssertEqual(cleanFailureCount, 0)
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

    /// An abandoned-message retry runs after this history slice's messages
    /// are staged. An account-wide auth failure there must abort the entire
    /// run before any cursor/counter/ledger movement. A history message saved
    /// by the executor's earlier, explicitly durable intermediate flush may
    /// remain; the frozen cursor safely replays that idempotent upsert.
    @MainActor
    func testAbandonedDrainAuthenticationFailureAbortsWithoutSpendingRecoveryState() async throws {
        try await seedLedgerRow(id: "blocked-by-auth", state: .abandoned)
        try await seedFailureCounter(2)
        apiClient.setHistoryResponsesByPageToken(makeSinglePageHistory(messageId: "m-new"))
        apiClient.getMessageResponses["m-new"] = makeFullMessage(id: "m-new")
        apiClient.getMessageResponses["blocked-by-auth"] = makeLargeBodyMessage(id: "blocked-by-auth")

        let sut = makeOrchestrator(
            messageProcessor: MessageProcessor(fetchAttachmentData: { _, _ in
                throw APIError.authenticationError
            })
        )
        do {
            _ = try await sut.performSync(
                progressHandler: { _, _ in },
                initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
            )
            XCTFail("The account-wide authentication error must abort the run")
        } catch let error as APIError {
            guard case .authenticationError = error else {
                return XCTFail("Expected authenticationError, got \(error)")
            }
        }

        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, Self.startingHistoryId)
        let checkpoint = try await fetchHistoryCheckpoint()
        XCTAssertNil(checkpoint)
        let failureCount = try await fetchFailureCounter()
        XCTAssertEqual(failureCount, 2, "The aborted run must not spend or reset the durable strike count")
        let rows = await fetchLedgerRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.gmailMessageId, "blocked-by-auth")
        XCTAssertEqual(rows.first?.state, AbandonedSyncMessage.State.abandoned.rawValue)
        let durablySavedSubset = await messageExists(id: "m-new")
        XCTAssertTrue(
            durablySavedSubset,
            "The earlier committed subset remains safe because the frozen cursor will replay it idempotently"
        )
    }

    // MARK: - History-recovery scenarios

    /// A clean recovery run advances the cursor to the profile's historyId,
    /// clears previously deferred rows (the re-scan recovered them), and
    /// resets the failure counter — success state committed only after the
    /// recovery's durable save.
    @MainActor
    func testCleanRecoveryAdvancesCursorAndCommitsSuccess() async throws {
        try await seedLedgerRow(id: "previously-failing", state: .deferred)
        try await seedFailureCounter(1)

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
        XCTAssertFalse(
            result.needsFollowUp,
            "A recovery warning is terminal when its replacement cursor advanced"
        )
        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, "7777", "A clean recovery advances to the profile historyId")
        let recovered = await messageExists(id: "m-rec")
        XCTAssertTrue(recovered)
        let rows = await fetchLedgerRows()
        XCTAssertTrue(rows.isEmpty, "A clean recovery clears recovered deferred rows")
        let consecutive = await failureTracker.consecutiveFailureCount
        XCTAssertEqual(consecutive, 0, "Recovery success must reset the counter after the save")
        let recoveryCheckpoint = try await fetchHistoryCheckpoint()
        XCTAssertNil(recoveryCheckpoint)
        let recoveryFailureCount = try await fetchFailureCounter()
        XCTAssertEqual(recoveryFailureCount, 0)
        let lastSuccess = await failureTracker.lastSuccessfulSyncTime
        XCTAssertNotNil(lastSuccess)
    }

    /// The pre-scan watermark: recovery must capture the profile cursor
    /// BEFORE enumerating the mailbox. Messages arriving mid-scan sort after
    /// a pre-scan watermark and stay covered by the next incremental sync; a
    /// post-scan capture stamps the cursor past arrivals the enumeration
    /// never saw, permanently skipping their deletions and label changes.
    @MainActor
    func testRecoveryCapturesProfileWatermarkBeforeEnumerating() async throws {
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

        // Sequenced profiles: only a capture made BEFORE the enumeration can
        // observe "7777" — any later capture sees "8888", so the cursor value
        // itself discriminates which capture was stamped.
        apiClient.profileResponses = [
            GmailProfile(
                emailAddress: Self.myEmail,
                messagesTotal: 1,
                threadsTotal: 1,
                historyId: "7777"
            )
        ]
        apiClient.profileResponse = GmailProfile(
            emailAddress: Self.myEmail,
            messagesTotal: 1,
            threadsTotal: 1,
            historyId: "8888"
        )

        let sut = makeOrchestrator()
        _ = try await sut.performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
        )

        let order = apiClient.endpointCallOrder
        guard let profileIndex = order.firstIndex(of: "getProfile"),
              let firstListIndex = order.firstIndex(of: "listMessages") else {
            XCTFail("Recovery must call both getProfile and listMessages; saw \(order)")
            return
        }
        XCTAssertLessThan(
            profileIndex, firstListIndex,
            "The watermark must be captured before the enumeration begins"
        )
        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, "7777", "The cursor advances to the FIRST (pre-scan) profile capture")
    }

    /// The chosen tradeoff of the pre-scan watermark: a profile outage now
    /// aborts recovery before any enumeration work instead of after saving
    /// pages — zero progress, cursor frozen, retried on the next trigger.
    @MainActor
    func testRecoveryProfileFailureAbortsBeforeEnumeration() async throws {
        apiClient.listHistoryError = APIError.historyIdExpired
        apiClient.getProfileError = APIError.timeout
        apiClient.listMessagesResponse = MessagesListResponse(
            messages: [MessageListItem(id: "m-rec", threadId: "t-m-rec")],
            nextPageToken: nil,
            resultSizeEstimate: 1
        )

        let sut = makeOrchestrator()
        do {
            _ = try await sut.performSync(
                progressHandler: { _, _ in },
                initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
            )
            XCTFail("A watermark failure must abort the recovery")
        } catch {
            // Expected.
        }

        XCTAssertEqual(
            apiClient.listMessagesCallCount, 0,
            "The enumeration must not start without a watermark"
        )
        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(historyId, Self.startingHistoryId)
        let lastSuccess = await failureTracker.lastSuccessfulSyncTime
        XCTAssertNil(lastSuccess)
    }

    /// The recovery-path mirror of the incremental failed-final-save tests:
    /// per-page saves land durably (attempt 1 succeeds — the recovered
    /// message survives), but the failing FINAL save must keep the cursor
    /// frozen and the tracker's success state untouched.
    @MainActor
    func testFailedRecoveryFinalSaveKeepsCursorFrozenAfterDurablePages() async throws {
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
        let failingContext = ScriptedSaveContext(
            error: NSError(domain: NSCocoaErrorDomain, code: NSManagedObjectContextLockingError),
            failingFromAttempt: 2
        )
        failingContext.persistentStoreCoordinator = testStack.persistentContainer.persistentStoreCoordinator
        failingContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        let sut = makeOrchestrator(makeSyncContext: { failingContext })
        do {
            _ = try await sut.performSync(
                progressHandler: { _, _ in },
                initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
            )
            XCTFail("A failed recovery final save must abort the run")
        } catch {
            // Expected.
        }

        XCTAssertGreaterThanOrEqual(failingContext.saveAttempts, 2, "Positive control: page save then final save")
        let recovered = await messageExists(id: "m-rec")
        XCTAssertTrue(recovered, "The per-page save landed durably before the final save failed")
        let historyId = await fetchAccountHistoryId()
        XCTAssertEqual(
            historyId, Self.startingHistoryId,
            "The pre-scan watermark staged into a failed save must not reach the store"
        )
        let lastSuccess = await failureTracker.lastSuccessfulSyncTime
        XCTAssertNil(lastSuccess, "commit(plan) must not run after a failed recovery save")
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
        let result = try await sut.performSync(
            progressHandler: { _, _ in },
            initialSyncFallback: { XCTFail("Account has a cursor; initial fallback must not run") }
        )

        XCTAssertTrue(result.needsFollowUp)
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
        let checkpoint = try await fetchHistoryCheckpoint()
        XCTAssertNil(checkpoint)
        let durableFailureCount = try await fetchFailureCounter()
        XCTAssertEqual(durableFailureCount, 1)
        let consecutive = await failureTracker.consecutiveFailureCount
        XCTAssertEqual(consecutive, 0, "Recovery strikes are checkpointed, not stored in UserDefaults")
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

    private func setAccountHistoryId(_ historyId: String?) async throws {
        let context = coreDataStack.newBackgroundContext()
        try await context.perform {
            let request = Account.fetchRequest()
            request.fetchLimit = 1
            guard let account = try context.fetch(request).first else {
                throw NSError(
                    domain: "IncrementalSyncCursorTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing test account"]
                )
            }
            account.historyId = historyId
        }
        try await coreDataStack.saveAsync(context: context)
    }

    @MainActor
    private func makeOrchestrator(
        conversationCreationError: Error? = nil,
        historyPageLimit: Int = SyncConfig.maxHistoryPagesPerForegroundSlice,
        authenticatedAccountEmail: (() -> String?)? = nil,
        messageProcessor: MessageProcessor = MessageProcessor(),
        makeSyncContext: (() -> NSManagedObjectContext)? = nil
    ) -> IncrementalSyncOrchestrator {
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
            messageProcessor: messageProcessor,
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
            failureTracker: failureTracker,
            historyPageLimit: historyPageLimit,
            authenticatedAccountEmail: authenticatedAccountEmail,
            makeSyncContext: makeSyncContext
        )
    }

    /// A save-scripted sync context attached to the test store, so a full
    /// orchestrator run stages real work and then fails at `context.save()`.
    private func makeFailingSaveContext() -> ScriptedSaveContext {
        let context = ScriptedSaveContext(
            error: NSError(domain: NSCocoaErrorDomain, code: NSManagedObjectContextLockingError)
        )
        context.persistentStoreCoordinator = testStack.persistentContainer.persistentStoreCoordinator
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
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

    /// Forces the persister to make an account-scoped attachment API request
    /// after the abandoned ID itself was fetched successfully.
    private func makeLargeBodyMessage(id: String) -> GmailMessage {
        GmailMessage(
            id: id,
            threadId: "t-\(id)",
            labelIds: ["INBOX"],
            snippet: "Snippet \(id)",
            historyId: nil,
            internalDate: "1700000000000",
            payload: MessagePart(
                partId: "",
                mimeType: "text/plain",
                filename: nil,
                headers: [
                    MessageHeader(name: "From", value: "Alice Smith <alice@example.com>"),
                    MessageHeader(name: "To", value: Self.myEmail),
                    MessageHeader(name: "Subject", value: "Subject \(id)"),
                    MessageHeader(name: "Content-Type", value: "text/plain; charset=UTF-8"),
                ],
                body: MessageBody(size: 30_000, data: nil, attachmentId: "att-\(id)"),
                parts: nil
            ),
            sizeEstimate: 30_000
        )
    }

    /// A complete history chain whose last page is terminal.
    private func makeHistoryPages(pageCount: Int) -> [(pageToken: String?, response: HistoryResponse)] {
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
                nextPageToken: index == pageCount - 1 ? nil : "p\(index + 1)",
                historyId: "\(4000 + index)"
            )
            return (pageToken: requestPageToken, response: response)
        }
    }

    private func makeDeletionHistoryResponse(
        nextPageToken: String?,
        historyId: String
    ) -> HistoryResponse {
        HistoryResponse(
            history: [
                HistoryRecord(
                    id: "5000",
                    messages: nil,
                    messagesAdded: nil,
                    messagesDeleted: [
                        HistoryMessageDeleted(
                            message: MessageListItem(
                                id: "m-unknown",
                                threadId: "t-unknown"
                            )
                        )
                    ],
                    labelsAdded: nil,
                    labelsRemoved: nil
                )
            ],
            nextPageToken: nextPageToken,
            historyId: historyId
        )
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

    private func fetchHistoryCheckpoint() async throws -> ForegroundHistoryCheckpoint? {
        try await ForegroundHistoryCheckpointStore().loadCompatible(
            accountEmail: Self.myEmail,
            startHistoryId: await fetchAccountHistoryId() ?? Self.startingHistoryId,
            in: coreDataStack.newBackgroundContext()
        )
    }

    private func seedHistoryCheckpoint(pageToken: String) async throws {
        let context = coreDataStack.newBackgroundContext()
        try await ForegroundHistoryCheckpointStore().stageProgress(
            accountEmail: Self.myEmail,
            startHistoryId: Self.startingHistoryId,
            pageToken: pageToken,
            in: context
        )
        try await coreDataStack.saveAsync(context: context)
    }

    private func seedFailureCounter(_ count: Int) async throws {
        let context = coreDataStack.newBackgroundContext()
        try await SyncFailureCounterCheckpointStore().stage(
            consecutiveFailureCount: count,
            accountEmail: Self.myEmail,
            in: context
        )
        try await coreDataStack.saveAsync(context: context)
    }

    private func fetchFailureCounter() async throws -> Int? {
        struct Payload: Decodable {
            let version: Int
            let consecutiveFailureCount: Int
        }

        let context = coreDataStack.newBackgroundContext()
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

    /// Thread-safe latch settable from a @Sendable save callback running on a
    /// Core Data context queue.
    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false

        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }

        func set() {
            lock.lock()
            defer { lock.unlock() }
            _value = true
        }
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
