import CoreData
import XCTest
@testable import esc_chatmail

final class SyncWindowCheckpointStoreTests: XCTestCase {
    private static let email = "user@example.com"

    private var testStack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!

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

    func testStageFreeze_stagesWithoutSavingAndLoadsAfterSave() async throws {
        let store = SyncWindowCheckpointStore.initialSync
        let context = coreDataStack.newBackgroundContext()

        try await store.stageFreeze(windowStart: 1_700_000_000, accountEmail: Self.email, in: context)

        let committedBeforeSave = try await committedRowCount(kind: SyncWindowCheckpoint.initialSyncKind)
        XCTAssertEqual(committedBeforeSave, 0, "The store stages into the caller's context and never saves")
        try await coreDataStack.saveAsync(context: context)

        let loaded = try await store.load(
            accountEmail: "USER@example.com",
            in: coreDataStack.newBackgroundContext()
        )
        XCTAssertEqual(loaded?.windowStart, 1_700_000_000)
    }

    func testLoad_otherAccountRowIsIgnored() async throws {
        let store = SyncWindowCheckpointStore.historyRecovery
        let context = coreDataStack.newBackgroundContext()
        try await store.stageFreeze(windowStart: 42, accountEmail: "other@example.com", in: context)
        try await coreDataStack.saveAsync(context: context)

        let loaded = try await store.load(accountEmail: Self.email, in: coreDataStack.newBackgroundContext())

        XCTAssertNil(loaded)
    }

    func testStageFreeze_replacesExistingRowsOfItsKindOnly() async throws {
        let initial = SyncWindowCheckpointStore.initialSync
        let recovery = SyncWindowCheckpointStore.historyRecovery
        let context = coreDataStack.newBackgroundContext()
        try await initial.stageFreeze(windowStart: 1, accountEmail: "other@example.com", in: context)
        try await recovery.stageFreeze(windowStart: 7, accountEmail: Self.email, in: context)
        try await coreDataStack.saveAsync(context: context)

        let second = coreDataStack.newBackgroundContext()
        try await initial.stageFreeze(windowStart: 2, accountEmail: Self.email, in: second)
        try await coreDataStack.saveAsync(context: second)

        let initialRows = try await committedRowCount(kind: SyncWindowCheckpoint.initialSyncKind)
        XCTAssertEqual(initialRows, 1)
        let reader = coreDataStack.newBackgroundContext()
        let loadedInitial = try await initial.load(accountEmail: Self.email, in: reader)
        XCTAssertEqual(loadedInitial?.windowStart, 2)
        let loadedRecovery = try await recovery.load(accountEmail: Self.email, in: reader)
        XCTAssertEqual(loadedRecovery?.windowStart, 7, "A freeze must not touch another run kind's row")
    }

    func testStageClear_deletesOnlyItsKind() async throws {
        let initial = SyncWindowCheckpointStore.initialSync
        let recovery = SyncWindowCheckpointStore.historyRecovery
        let context = coreDataStack.newBackgroundContext()
        try await initial.stageFreeze(windowStart: 1, accountEmail: Self.email, in: context)
        try await recovery.stageFreeze(windowStart: 2, accountEmail: Self.email, in: context)
        try await coreDataStack.saveAsync(context: context)

        let clearing = coreDataStack.newBackgroundContext()
        try await initial.stageClear(in: clearing)
        try await coreDataStack.saveAsync(context: clearing)

        let initialRows = try await committedRowCount(kind: SyncWindowCheckpoint.initialSyncKind)
        XCTAssertEqual(initialRows, 0)
        let recoveryRows = try await committedRowCount(kind: SyncWindowCheckpoint.historyRecoveryKind)
        XCTAssertEqual(recoveryRows, 1)
    }

    func testLoad_malformedPayloadIsIgnored() async throws {
        let context = coreDataStack.newBackgroundContext()
        await context.perform {
            let row = SyncCheckpoint(context: context)
            row.id = UUID()
            row.kind = SyncWindowCheckpoint.initialSyncKind
            row.accountEmail = Self.email
            row.pendingMessageIdsJSON = "{\"version\":99,\"windowStart\":1}"
            row.createdAt = Date()
            row.updatedAt = Date()
        }
        try await coreDataStack.saveAsync(context: context)

        let loaded = try await SyncWindowCheckpointStore.initialSync.load(
            accountEmail: Self.email,
            in: coreDataStack.newBackgroundContext()
        )

        XCTAssertNil(loaded, "An unknown payload version must read as no frozen window")
    }

    private func committedRowCount(kind: String) async throws -> Int {
        let context = coreDataStack.newBackgroundContext()
        return try await context.perform {
            let request = SyncCheckpoint.fetchRequest()
            request.predicate = NSPredicate(format: "kind == %@", kind)
            request.includesPendingChanges = false
            return try context.count(for: request)
        }
    }
}
