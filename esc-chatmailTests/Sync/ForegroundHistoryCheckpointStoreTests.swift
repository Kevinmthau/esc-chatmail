import CoreData
import XCTest
@testable import esc_chatmail

final class ForegroundHistoryCheckpointStoreTests: XCTestCase {
    private static let email = "user@example.com"
    private static let historyId = "history-100"

    private var testStack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!
    private let store = ForegroundHistoryCheckpointStore()

    override func setUp() async throws {
        try await super.setUp()
        testStack = TestCoreDataStack(storeKind: .sqlite)
        coreDataStack = CoreDataStack(
            persistentContainerForTesting: testStack.persistentContainer
        )
        try await seedAccount(email: Self.email, historyId: Self.historyId)
    }

    override func tearDown() async throws {
        coreDataStack = nil
        testStack = nil
        try await super.tearDown()
    }

    func testCreateLoadAndUpdateRoundTrip_preservesIdentityAndOpaqueToken() async throws {
        let firstContext = coreDataStack.newBackgroundContext()
        try await store.stageProgress(
            accountEmail: Self.email,
            startHistoryId: Self.historyId,
            pageToken: " token-with-significant-spaces ",
            in: firstContext
        )
        try await coreDataStack.saveAsync(context: firstContext)

        let loaded = try await store.loadCompatible(
            accountEmail: "USER@example.com",
            startHistoryId: Self.historyId,
            in: coreDataStack.newBackgroundContext()
        )
        XCTAssertEqual(
            loaded,
            ForegroundHistoryCheckpoint(
                accountEmail: Self.email,
                startHistoryId: Self.historyId,
                pageToken: " token-with-significant-spaces "
            )
        )

        let firstRaw = try await fetchRawRows().only
        let secondContext = coreDataStack.newBackgroundContext()
        try await store.stageProgress(
            accountEmail: Self.email,
            startHistoryId: Self.historyId,
            pageToken: "page-3",
            in: secondContext
        )
        try await coreDataStack.saveAsync(context: secondContext)

        let secondRaw = try await fetchRawRows().only
        XCTAssertEqual(secondRaw.id, firstRaw.id)
        XCTAssertEqual(secondRaw.createdAt, firstRaw.createdAt)
        XCTAssertGreaterThanOrEqual(secondRaw.updatedAt, firstRaw.updatedAt)
        XCTAssertEqual(secondRaw.pageToken, "page-3")
        let updatedRows = try await fetchRawRows()
        XCTAssertEqual(updatedRows.count, 1)
    }

    func testChangedCursorRejectsOldRow_andDeleteInsertReplacementSavesAsOneKind() async throws {
        let seedContext = coreDataStack.newBackgroundContext()
        try await store.stageProgress(
            accountEmail: Self.email,
            startHistoryId: Self.historyId,
            pageToken: "old-token",
            in: seedContext
        )
        try await coreDataStack.saveAsync(context: seedContext)

        let changedHistoryId = "history-200"
        let accountContext = coreDataStack.newBackgroundContext()
        try await accountContext.perform {
            let account = try XCTUnwrap(accountContext.fetch(Account.fetchRequest()).first)
            account.historyId = changedHistoryId
        }
        try await coreDataStack.saveAsync(context: accountContext)

        let replacementContext = coreDataStack.newBackgroundContext()
        let stale = try await store.loadCompatible(
            accountEmail: Self.email,
            startHistoryId: changedHistoryId,
            in: replacementContext
        )
        XCTAssertNil(stale)
        try await store.stageProgress(
            accountEmail: Self.email,
            startHistoryId: changedHistoryId,
            pageToken: "new-token",
            in: replacementContext
        )
        try await coreDataStack.saveAsync(context: replacementContext)

        let rows = try await fetchRawRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.startHistoryId, changedHistoryId)
        XCTAssertEqual(rows.first?.pageToken, "new-token")
    }

    func testMismatchedAccountAndMalformedPayloadAreDeleted() async throws {
        let rawContext = coreDataStack.newBackgroundContext()
        await rawContext.perform {
            let row = SyncCheckpoint(context: rawContext)
            row.id = UUID()
            row.kind = ForegroundHistoryCheckpoint.kind
            row.accountEmail = "other@example.com"
            row.startHistoryId = Self.historyId
            row.pageToken = "unsafe-token"
            row.pendingMessageIdsJSON = #"{"version":1,"pendingMessageIds":["unfinished"],"consecutiveFailureCount":1}"#
            row.createdAt = Date()
            row.updatedAt = Date()
        }
        try await coreDataStack.saveAsync(context: rawContext)

        let loadContext = coreDataStack.newBackgroundContext()
        let loaded = try await store.loadCompatible(
            accountEmail: Self.email,
            startHistoryId: Self.historyId,
            in: loadContext
        )
        XCTAssertNil(loaded)
        try await coreDataStack.saveAsync(context: loadContext)
        let remainingRows = try await fetchRawRows()
        XCTAssertTrue(remainingRows.isEmpty)
    }

    func testMatchingRowWithPendingPayloadIsRejectedInsteadOfSkippingFutureWork() async throws {
        let rawContext = coreDataStack.newBackgroundContext()
        await rawContext.perform {
            let row = SyncCheckpoint(context: rawContext)
            row.id = UUID()
            row.kind = ForegroundHistoryCheckpoint.kind
            row.accountEmail = Self.email
            row.startHistoryId = Self.historyId
            row.pageToken = "unsafe-token"
            row.pendingMessageIdsJSON = #"{"pendingMessageIds":["unfinished"]}"#
            row.createdAt = Date()
            row.updatedAt = Date()
        }
        try await coreDataStack.saveAsync(context: rawContext)

        let loadContext = coreDataStack.newBackgroundContext()
        let loaded = try await store.loadCompatible(
            accountEmail: Self.email,
            startHistoryId: Self.historyId,
            in: loadContext
        )
        XCTAssertNil(loaded)
        try await coreDataStack.saveAsync(context: loadContext)
        let remainingRows = try await fetchRawRows()
        XCTAssertTrue(remainingRows.isEmpty)
    }

    func testWhitespaceTokenThrowsWithoutStaging() async throws {
        let context = coreDataStack.newBackgroundContext()

        do {
            try await store.stageProgress(
                accountEmail: Self.email,
                startHistoryId: Self.historyId,
                pageToken: "  \n ",
                in: context
            )
            XCTFail("Expected emptyPageToken")
        } catch let error as ForegroundHistoryCheckpointStoreError {
            XCTAssertEqual(error, .emptyPageToken)
        }

        XCTAssertFalse(context.hasChanges)
    }

    func testFailedSaveLeavesPreviouslyDurableCheckpointUntouched() async throws {
        let initialContext = coreDataStack.newBackgroundContext()
        try await store.stageProgress(
            accountEmail: Self.email,
            startHistoryId: Self.historyId,
            pageToken: "durable-token",
            in: initialContext
        )
        try await coreDataStack.saveAsync(context: initialContext)

        let failingContext = ScriptedSaveContext(
            error: NSError(
                domain: NSCocoaErrorDomain,
                code: NSManagedObjectContextLockingError
            )
        )
        failingContext.persistentStoreCoordinator = testStack.persistentContainer
            .persistentStoreCoordinator
        failingContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        try await store.stageProgress(
            accountEmail: Self.email,
            startHistoryId: Self.historyId,
            pageToken: "must-not-land",
            in: failingContext
        )
        do {
            try await failingContext.perform { try failingContext.save() }
            XCTFail("Expected scripted save failure")
        } catch {
            // Expected.
        }
        await failingContext.perform { failingContext.reset() }

        let loaded = try await store.loadCompatible(
            accountEmail: Self.email,
            startHistoryId: Self.historyId,
            in: coreDataStack.newBackgroundContext()
        )
        XCTAssertEqual(loaded?.pageToken, "durable-token")
    }

    func testStageClearDeletesTheCheckpoint() async throws {
        let context = coreDataStack.newBackgroundContext()
        try await store.stageProgress(
            accountEmail: Self.email,
            startHistoryId: Self.historyId,
            pageToken: "page-2",
            in: context
        )
        try await coreDataStack.saveAsync(context: context)

        let clearContext = coreDataStack.newBackgroundContext()
        try await store.stageClear(in: clearContext)
        try await coreDataStack.saveAsync(context: clearContext)
        let remainingRows = try await fetchRawRows()
        XCTAssertTrue(remainingRows.isEmpty)
    }

    private func seedAccount(email: String, historyId: String) async throws {
        let context = coreDataStack.newBackgroundContext()
        await context.perform {
            _ = AccountBuilder()
                .withEmail(email)
                .withHistoryId(historyId)
                .build(in: context)
        }
        try await coreDataStack.saveAsync(context: context)
    }

    private struct RawCheckpoint {
        let id: UUID
        let createdAt: Date
        let updatedAt: Date
        let startHistoryId: String?
        let pageToken: String?
    }

    private func fetchRawRows() async throws -> [RawCheckpoint] {
        let context = coreDataStack.newBackgroundContext()
        return try await context.perform {
            let request = SyncCheckpoint.fetchRequest()
            request.predicate = NSPredicate(
                format: "kind == %@",
                ForegroundHistoryCheckpoint.kind
            )
            return try context.fetch(request).map {
                RawCheckpoint(
                    id: $0.id,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt,
                    startHistoryId: $0.startHistoryId,
                    pageToken: $0.pageToken
                )
            }
        }
    }
}

private extension Array {
    var only: Element {
        get throws {
            guard count == 1, let first else {
                throw NSError(
                    domain: "ForegroundHistoryCheckpointStoreTests",
                    code: count
                )
            }
            return first
        }
    }
}
