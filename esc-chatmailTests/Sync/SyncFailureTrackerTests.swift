import XCTest
@testable import esc_chatmail

final class SyncFailureTrackerTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var sut: SyncFailureTracker!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "SyncFailureTrackerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        sut = SyncFailureTracker(defaults: defaults, coreDataStack: .shared)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        sut = nil
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - Initial state

    func testInitialState_noRecordedFailures() async {
        let count = await sut.consecutiveFailureCount
        XCTAssertEqual(count, 0)
        let ids = await sut.persistentFailedIds
        XCTAssertEqual(ids, [])
    }

    func testInitialState_lastSuccessfulSyncTimeIsNil() async {
        let time = await sut.lastSuccessfulSyncTime
        XCTAssertNil(time)
    }

    // MARK: - recordSuccess

    func testRecordSuccess_resetsFailureCounter() async {
        await sut.recordFailure(failedIds: ["a", "b"])
        await sut.recordSuccess()

        let count = await sut.consecutiveFailureCount
        XCTAssertEqual(count, 0)
    }

    func testRecordSuccess_clearsPersistentFailedIds() async {
        await sut.recordFailure(failedIds: ["a", "b"])
        await sut.recordSuccess()

        let ids = await sut.persistentFailedIds
        XCTAssertEqual(ids, [])
    }

    func testRecordSuccess_updatesLastSuccessfulSyncTime() async {
        let before = Date()
        await sut.recordSuccess()
        let time = await sut.lastSuccessfulSyncTime

        XCTAssertNotNil(time)
        XCTAssertGreaterThanOrEqual(time!.timeIntervalSince1970, before.addingTimeInterval(-1).timeIntervalSince1970)
    }

    // MARK: - recordFailure

    func testRecordFailure_emptyIds_noChange() async {
        await sut.recordFailure(failedIds: [])

        let count = await sut.consecutiveFailureCount
        XCTAssertEqual(count, 0)
        let ids = await sut.persistentFailedIds
        XCTAssertEqual(ids, [])
    }

    func testRecordFailure_singleBatch_incrementsCounterAndTracksIds() async {
        await sut.recordFailure(failedIds: ["id-1", "id-2"])

        let count = await sut.consecutiveFailureCount
        XCTAssertEqual(count, 1)
        let ids = Set(await sut.persistentFailedIds)
        XCTAssertEqual(ids, Set(["id-1", "id-2"]))
    }

    func testRecordFailure_multipleBatches_accumulatesCounterAndIds() async {
        await sut.recordFailure(failedIds: ["a"])
        await sut.recordFailure(failedIds: ["b", "c"])

        let count = await sut.consecutiveFailureCount
        XCTAssertEqual(count, 2)
        let ids = Set(await sut.persistentFailedIds)
        XCTAssertEqual(ids, Set(["a", "b", "c"]))
    }

    func testRecordFailure_duplicateIdsAcrossBatches_notDoubled() async {
        await sut.recordFailure(failedIds: ["a", "b"])
        await sut.recordFailure(failedIds: ["b", "c"])

        let ids = await sut.persistentFailedIds
        // b should only appear once
        XCTAssertEqual(ids.filter { $0 == "b" }.count, 1)
        XCTAssertEqual(Set(ids), Set(["a", "b", "c"]))
    }

    func testRecordFailure_hugeBatchKeepsEveryTrackedId() async {
        // Tracked IDs must never be truncated: dropped IDs would be silently
        // lost when the escape hatch advances the cursor past them. Bounding
        // happens at the drain (maxAbandonedMessagesPerSync), not here.
        let oversized = (0..<(SyncConfig.maxFailedMessagesBeforeAdvance * 2 + 5)).map { "id-\($0)" }

        await sut.recordFailure(failedIds: oversized)

        let ids = await sut.persistentFailedIds
        XCTAssertEqual(ids, oversized, "Every failed ID must stay tracked until durably abandoned")
    }

    // MARK: - shouldAdvanceHistoryId

    func testShouldAdvanceHistoryId_noFailures_returnsTrueAndRecordsSuccess() async {
        // Seed a failure first
        await sut.recordFailure(failedIds: ["x"])

        let advance = await sut.shouldAdvanceHistoryId(hadFailures: false, latestHistoryId: "100")

        XCTAssertTrue(advance)
        // Success side effect: counter reset
        let count = await sut.consecutiveFailureCount
        XCTAssertEqual(count, 0)
    }

    func testShouldAdvanceHistoryId_hadFailuresBelowMax_returnsFalse() async {
        // Seed one failure (below max threshold)
        await sut.recordFailure(failedIds: ["x"])

        let advance = await sut.shouldAdvanceHistoryId(hadFailures: true, latestHistoryId: "100")

        XCTAssertFalse(advance)
        // Counter unchanged
        let count = await sut.consecutiveFailureCount
        XCTAssertEqual(count, 1)
    }

    // MARK: - reset

    func testReset_clearsAllTrackingState() async {
        await sut.recordFailure(failedIds: ["a", "b"])

        await sut.reset()

        let count = await sut.consecutiveFailureCount
        XCTAssertEqual(count, 0)
        let ids = await sut.persistentFailedIds
        XCTAssertEqual(ids, [])
    }
}
