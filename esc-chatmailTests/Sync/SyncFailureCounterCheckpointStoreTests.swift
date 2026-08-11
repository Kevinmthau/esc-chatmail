import CoreData
import XCTest
@testable import esc_chatmail

final class SyncFailureCounterCheckpointStoreTests: XCTestCase {
    private static let email = "user@example.com"

    private var testStack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!
    private let store = SyncFailureCounterCheckpointStore()

    override func setUp() async throws {
        try await super.setUp()
        testStack = TestCoreDataStack(storeKind: .sqlite)
        coreDataStack = CoreDataStack(
            persistentContainerForTesting: testStack.persistentContainer
        )
    }

    override func tearDown() async throws {
        coreDataStack = nil
        testStack = nil
        try await super.tearDown()
    }

    func testAbsentRowImportsLegacyCountForCommittedMatchingAccount() async throws {
        try await seedCommittedAccount(email: Self.email)
        let context = coreDataStack.newBackgroundContext()

        let loaded = try await store.load(
            accountEmail: "USER@example.com",
            legacyConsecutiveFailureCount: 2,
            in: context
        )

        XCTAssertEqual(loaded.consecutiveFailureCount, 2)
        let committedRowsBeforeSave = try await fetchRawRows()
        XCTAssertTrue(
            committedRowsBeforeSave.isEmpty,
            "Load initializes in the caller context but must never save it"
        )
        try await coreDataStack.saveAsync(context: context)

        let row = try await onlyRawRow()
        XCTAssertEqual(row.kind, SyncFailureCounterCheckpoint.kind)
        XCTAssertEqual(row.accountEmail, "USER@example.com")
        XCTAssertNil(row.startHistoryId)
        XCTAssertNil(row.pageToken)
        XCTAssertEqual(row.decodedPayload, Payload(version: 1, consecutiveFailureCount: 2))
    }

    func testAbsentRowDoesNotImportLegacyForOnlyPendingAccount() async throws {
        let context = coreDataStack.newBackgroundContext()
        await context.perform {
            _ = AccountBuilder()
                .withEmail(Self.email)
                .withHistoryId("history-pending")
                .build(in: context)
        }

        let loaded = try await store.load(
            accountEmail: Self.email,
            legacyConsecutiveFailureCount: 2,
            in: context
        )

        XCTAssertEqual(
            loaded.consecutiveFailureCount, 0,
            "An unsaved Account cannot prove which account owns legacy defaults"
        )
        try await coreDataStack.saveAsync(context: context)
        let row = try await onlyRawRow()
        XCTAssertEqual(
            row.decodedPayload,
            Payload(version: 1, consecutiveFailureCount: 0)
        )
    }

    func testAbsentRowSanitizesNegativeLegacyCountToZero() async throws {
        try await seedCommittedAccount(email: Self.email)
        let context = coreDataStack.newBackgroundContext()

        let loaded = try await store.load(
            accountEmail: Self.email,
            legacyConsecutiveFailureCount: -7,
            in: context
        )
        try await coreDataStack.saveAsync(context: context)

        XCTAssertEqual(loaded.consecutiveFailureCount, 0)
        let row = try await onlyRawRow()
        XCTAssertEqual(
            row.decodedPayload,
            Payload(version: 1, consecutiveFailureCount: 0)
        )
    }

    func testPermanentZeroRowWinsOverLaterLegacyValue() async throws {
        try await seedCommittedAccount(email: Self.email)
        let seedContext = coreDataStack.newBackgroundContext()
        try await store.stage(
            consecutiveFailureCount: 0,
            accountEmail: Self.email,
            in: seedContext
        )
        try await coreDataStack.saveAsync(context: seedContext)
        let seededID = try await onlyRawRow().id

        let loadContext = coreDataStack.newBackgroundContext()
        let loaded = try await store.load(
            accountEmail: "USER@EXAMPLE.COM",
            legacyConsecutiveFailureCount: 3,
            in: loadContext
        )
        try await coreDataStack.saveAsync(context: loadContext)

        XCTAssertEqual(loaded.consecutiveFailureCount, 0)
        let row = try await onlyRawRow()
        XCTAssertEqual(row.id, seededID)
        XCTAssertEqual(row.decodedPayload, Payload(version: 1, consecutiveFailureCount: 0))
    }

    func testMismatchedExistingRowResetsToZeroWithoutLegacyFallback() async throws {
        try await seedCommittedAccount(email: Self.email)
        let originalID = UUID()
        try await seedRawCounter(
            id: originalID,
            accountEmail: "other@example.com",
            payloadJSON: payloadJSON(count: 2)
        )

        let context = coreDataStack.newBackgroundContext()
        let loaded = try await store.load(
            accountEmail: Self.email,
            legacyConsecutiveFailureCount: 3,
            in: context
        )

        XCTAssertEqual(loaded.consecutiveFailureCount, 0)
        let durableBeforeSave = try await onlyRawRow()
        XCTAssertEqual(
            durableBeforeSave.accountEmail, "other@example.com",
            "Repair remains staged until the caller saves"
        )
        try await coreDataStack.saveAsync(context: context)

        let repaired = try await onlyRawRow()
        XCTAssertEqual(repaired.id, originalID, "Repair should reuse the existing row")
        XCTAssertEqual(repaired.accountEmail, Self.email)
        XCTAssertEqual(repaired.decodedPayload, Payload(version: 1, consecutiveFailureCount: 0))
    }

    func testMalformedExistingRowResetsToZeroWithoutLegacyFallback() async throws {
        try await seedCommittedAccount(email: Self.email)
        try await seedRawCounter(
            accountEmail: Self.email,
            startHistoryId: "must-be-cleared",
            pageToken: "must-be-cleared",
            payloadJSON: payloadJSON(count: -1)
        )

        let context = coreDataStack.newBackgroundContext()
        let loaded = try await store.load(
            accountEmail: Self.email,
            legacyConsecutiveFailureCount: 3,
            in: context
        )
        try await coreDataStack.saveAsync(context: context)

        XCTAssertEqual(loaded.consecutiveFailureCount, 0)
        let repaired = try await onlyRawRow()
        XCTAssertNil(repaired.startHistoryId)
        XCTAssertNil(repaired.pageToken)
        XCTAssertEqual(repaired.decodedPayload, Payload(version: 1, consecutiveFailureCount: 0))
    }

    func testStageUpdatePreservesIdentityAndCreatedAt() async throws {
        let firstContext = coreDataStack.newBackgroundContext()
        try await store.stage(
            consecutiveFailureCount: 1,
            accountEmail: Self.email,
            in: firstContext
        )
        try await coreDataStack.saveAsync(context: firstContext)
        let first = try await onlyRawRow()

        let secondContext = coreDataStack.newBackgroundContext()
        try await store.stage(
            consecutiveFailureCount: 2,
            accountEmail: "USER@example.com",
            in: secondContext
        )
        try await coreDataStack.saveAsync(context: secondContext)

        let second = try await onlyRawRow()
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.createdAt, first.createdAt)
        XCTAssertGreaterThanOrEqual(second.updatedAt, first.updatedAt)
        XCTAssertEqual(second.decodedPayload, Payload(version: 1, consecutiveFailureCount: 2))
        XCTAssertNil(second.startHistoryId)
        XCTAssertNil(second.pageToken)
    }

    func testFailedSaveLeavesPreviouslyDurableCounterUntouched() async throws {
        let seedContext = coreDataStack.newBackgroundContext()
        try await store.stage(
            consecutiveFailureCount: 1,
            accountEmail: Self.email,
            in: seedContext
        )
        try await coreDataStack.saveAsync(context: seedContext)

        let failingContext = ScriptedSaveContext(
            error: NSError(
                domain: NSCocoaErrorDomain,
                code: NSManagedObjectContextLockingError
            )
        )
        failingContext.persistentStoreCoordinator = testStack.persistentContainer
            .persistentStoreCoordinator
        failingContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        try await store.stage(
            consecutiveFailureCount: 2,
            accountEmail: Self.email,
            in: failingContext
        )

        do {
            try await failingContext.perform { try failingContext.save() }
            XCTFail("Expected scripted save failure")
        } catch {
            // Expected.
        }
        await failingContext.perform { failingContext.reset() }

        let durable = try await onlyRawRow()
        XCTAssertEqual(durable.decodedPayload, Payload(version: 1, consecutiveFailureCount: 1))
    }

    func testCompatibleRowWinsAndDuplicateRowsAreCleanedUp() async throws {
        let selectedID = UUID()
        let selectedPayloadJSON = payloadJSON(count: 2)
        let mismatchedPayloadJSON = payloadJSON(count: 99)
        let context = coreDataStack.newBackgroundContext()
        await context.perform {
            let selected = SyncCheckpoint(context: context)
            selected.id = selectedID
            selected.kind = SyncFailureCounterCheckpoint.kind
            selected.accountEmail = Self.email
            selected.startHistoryId = nil
            selected.pageToken = nil
            selected.pendingMessageIdsJSON = selectedPayloadJSON
            selected.createdAt = Date(timeIntervalSince1970: 100)
            selected.updatedAt = Date(timeIntervalSince1970: 100)

            let newerMismatch = SyncCheckpoint(context: context)
            newerMismatch.id = UUID()
            newerMismatch.kind = SyncFailureCounterCheckpoint.kind
            newerMismatch.accountEmail = "other@example.com"
            newerMismatch.startHistoryId = nil
            newerMismatch.pageToken = nil
            newerMismatch.pendingMessageIdsJSON = mismatchedPayloadJSON
            newerMismatch.createdAt = Date(timeIntervalSince1970: 200)
            newerMismatch.updatedAt = Date(timeIntervalSince1970: 200)
        }

        let loaded = try await store.load(
            accountEmail: "USER@example.com",
            legacyConsecutiveFailureCount: 3,
            in: context
        )
        let stagedCount = try await context.perform {
            try context.fetch(SyncCheckpoint.fetchRequest()).filter {
                $0.kind == SyncFailureCounterCheckpoint.kind
            }.count
        }
        XCTAssertEqual(loaded.consecutiveFailureCount, 2)
        XCTAssertEqual(stagedCount, 1)
        try await coreDataStack.saveAsync(context: context)

        let row = try await onlyRawRow()
        XCTAssertEqual(row.id, selectedID)
        XCTAssertEqual(row.decodedPayload, Payload(version: 1, consecutiveFailureCount: 2))
    }

    func testDifferentCheckpointKindsCoexist() async throws {
        let context = coreDataStack.newBackgroundContext()
        await context.perform {
            let foreground = SyncCheckpoint(context: context)
            foreground.id = UUID()
            foreground.kind = "foregroundHistory.v1"
            foreground.accountEmail = Self.email
            foreground.startHistoryId = "history-1"
            foreground.pageToken = "page-2"
            foreground.pendingMessageIdsJSON = #"{"version":1}"#
            foreground.createdAt = Date()
            foreground.updatedAt = Date()
        }
        try await store.stage(
            consecutiveFailureCount: 1,
            accountEmail: Self.email,
            in: context
        )
        try await coreDataStack.saveAsync(context: context)

        let rows = try await fetchAllRawRows()
        XCTAssertEqual(Set(rows.map(\.kind)), ["foregroundHistory.v1", SyncFailureCounterCheckpoint.kind])
        XCTAssertEqual(
            rows.first(where: { $0.kind == "foregroundHistory.v1" })?.pageToken,
            "page-2"
        )
        XCTAssertEqual(
            rows.first(where: { $0.kind == SyncFailureCounterCheckpoint.kind })?.decodedPayload,
            Payload(version: 1, consecutiveFailureCount: 1)
        )
    }

    func testNegativeStageThrowsWithoutChanges() async throws {
        let context = coreDataStack.newBackgroundContext()

        do {
            try await store.stage(
                consecutiveFailureCount: -1,
                accountEmail: Self.email,
                in: context
            )
            XCTFail("Expected invalidFailureCount")
        } catch let error as SyncFailureCounterCheckpointStoreError {
            XCTAssertEqual(error, .invalidFailureCount(-1))
        }

        let hasChanges = await context.perform { context.hasChanges }
        XCTAssertFalse(hasChanges)
    }

    private struct Payload: Codable, Equatable {
        let version: Int
        let consecutiveFailureCount: Int
    }

    private struct RawCheckpoint {
        let id: UUID
        let kind: String
        let accountEmail: String
        let startHistoryId: String?
        let pageToken: String?
        let payloadJSON: String?
        let createdAt: Date
        let updatedAt: Date

        var decodedPayload: Payload? {
            guard let payloadJSON,
                  let data = payloadJSON.data(using: .utf8) else {
                return nil
            }
            return try? JSONDecoder().decode(Payload.self, from: data)
        }
    }

    private func seedCommittedAccount(email: String) async throws {
        let context = coreDataStack.newBackgroundContext()
        await context.perform {
            _ = AccountBuilder()
                .withEmail(email)
                .withHistoryId("history-1")
                .build(in: context)
        }
        try await coreDataStack.saveAsync(context: context)
    }

    private func seedRawCounter(
        id: UUID = UUID(),
        accountEmail: String,
        startHistoryId: String? = nil,
        pageToken: String? = nil,
        payloadJSON: String
    ) async throws {
        let context = coreDataStack.newBackgroundContext()
        await context.perform {
            let row = SyncCheckpoint(context: context)
            row.id = id
            row.kind = SyncFailureCounterCheckpoint.kind
            row.accountEmail = accountEmail
            row.startHistoryId = startHistoryId
            row.pageToken = pageToken
            row.pendingMessageIdsJSON = payloadJSON
            row.createdAt = Date(timeIntervalSince1970: 100)
            row.updatedAt = Date(timeIntervalSince1970: 100)
        }
        try await coreDataStack.saveAsync(context: context)
    }

    private func payloadJSON(count: Int) -> String {
        let data = try! JSONEncoder().encode(
            Payload(version: 1, consecutiveFailureCount: count)
        )
        return String(data: data, encoding: .utf8)!
    }

    private func onlyRawRow() async throws -> RawCheckpoint {
        let rows = try await fetchRawRows()
        return try XCTUnwrap(rows.count == 1 ? rows.first : nil)
    }

    private func fetchRawRows() async throws -> [RawCheckpoint] {
        try await fetchAllRawRows().filter {
            $0.kind == SyncFailureCounterCheckpoint.kind
        }
    }

    private func fetchAllRawRows() async throws -> [RawCheckpoint] {
        let context = coreDataStack.newBackgroundContext()
        return try await context.perform {
            try context.fetch(SyncCheckpoint.fetchRequest()).map {
                RawCheckpoint(
                    id: $0.id,
                    kind: $0.kind,
                    accountEmail: $0.accountEmail,
                    startHistoryId: $0.startHistoryId,
                    pageToken: $0.pageToken,
                    payloadJSON: $0.pendingMessageIdsJSON,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt
                )
            }
        }
    }
}
