import XCTest
import CoreData
@testable import esc_chatmail

final class ModificationTrackerTests: XCTestCase {
    override func tearDown() async throws {
        await ModificationTracker.shared.reset()
        try await super.tearDown()
    }

    func testModifiedIDsStayWithTheirRunUntilThatRunCommits() async throws {
        let ids = try makeConversationIDs(count: 2)
        let tracker = ModificationTracker.shared
        let firstRun = await tracker.beginTransaction()
        let secondRun = await tracker.beginTransaction()

        await tracker.trackModifiedConversation(ids[0], in: firstRun)
        await tracker.trackModifiedConversation(ids[1], in: secondRun)

        let firstRunCountBeforeCommit = await tracker.modificationCount(in: firstRun)
        let secondRunCountBeforeCommit = await tracker.modificationCount(in: secondRun)

        XCTAssertEqual(firstRunCountBeforeCommit, 1)
        XCTAssertEqual(secondRunCountBeforeCommit, 1)

        let secondRunIDs = await tracker.commitTransaction(secondRun)
        let firstRunCountAfterSecondCommit = await tracker.modificationCount(in: firstRun)
        let transactionCountAfterSecondCommit = await tracker.transactionCount

        XCTAssertEqual(secondRunIDs, Set([ids[1]]))
        XCTAssertEqual(firstRunCountAfterSecondCommit, 1)
        XCTAssertEqual(transactionCountAfterSecondCommit, 2)
    }

    func testRollbackDoesNotLeakOrClearAnotherRunsIDs() async throws {
        let ids = try makeConversationIDs(count: 2)
        let tracker = ModificationTracker.shared
        let cancelledRun = await tracker.beginTransaction()
        let successfulRun = await tracker.beginTransaction()

        await tracker.trackModifiedConversation(ids[0], in: cancelledRun)
        await tracker.trackModifiedConversation(ids[1], in: successfulRun)

        await tracker.rollbackTransaction(cancelledRun)
        let successfulRunIDs = await tracker.commitTransaction(successfulRun)
        let cancelledRunCountAfterRollback = await tracker.modificationCount(in: cancelledRun)

        XCTAssertEqual(successfulRunIDs, Set([ids[1]]))
        XCTAssertEqual(cancelledRunCountAfterRollback, 0)

        await tracker.consumeCommittedTransaction(successfulRun)
        let transactionCountAfterCleanup = await tracker.transactionCount
        XCTAssertEqual(transactionCountAfterCleanup, 0)
    }

    func testCommittedTransactionRemainsPendingUntilExplicitConsume() async throws {
        let ids = try makeConversationIDs(count: 1)
        let tracker = ModificationTracker.shared
        let run = await tracker.beginTransaction()

        await tracker.trackModifiedConversation(ids[0], in: run)

        let committedIDs = await tracker.commitTransaction(run)
        let transactionCountAfterCommit = await tracker.transactionCount

        XCTAssertEqual(committedIDs, Set([ids[0]]))
        XCTAssertEqual(transactionCountAfterCommit, 1)

        await tracker.consumeCommittedTransaction(run)
        let transactionCountAfterConsume = await tracker.transactionCount
        XCTAssertEqual(transactionCountAfterConsume, 0)
    }

    func testModifiedConversationsSnapshotDoesNotCommitRun() async throws {
        let ids = try makeConversationIDs(count: 1)
        let tracker = ModificationTracker.shared
        let run = await tracker.beginTransaction()

        await tracker.trackModifiedConversation(ids[0], in: run)

        let snapshot = await tracker.modifiedConversations(in: run)
        let transactionCountAfterSnapshot = await tracker.transactionCount
        let committedIDs = await tracker.commitTransaction(run)

        XCTAssertEqual(snapshot, Set([ids[0]]))
        XCTAssertEqual(transactionCountAfterSnapshot, 1)
        XCTAssertEqual(committedIDs, Set([ids[0]]))

        await tracker.consumeCommittedTransaction(run)
    }

    func testDisplayNameOnlyConversationsStaySeparateFromRollupIDs() async throws {
        let ids = try makeConversationIDs(count: 2)
        let tracker = ModificationTracker.shared
        let run = await tracker.beginTransaction()

        await tracker.trackModifiedConversation(ids[0], in: run)
        await tracker.trackDisplayNameOnlyConversations(Set([ids[1]]), in: run)

        let modifiedIDs = await tracker.modifiedConversations(in: run)
        let displayNameOnlyIDs = await tracker.displayNameOnlyConversations(in: run)
        let committedIDs = await tracker.commitTransaction(run)

        XCTAssertEqual(modifiedIDs, Set([ids[0]]))
        XCTAssertEqual(displayNameOnlyIDs, Set([ids[1]]))
        XCTAssertEqual(committedIDs, Set([ids[0]]))

        await tracker.consumeCommittedTransaction(run)
    }

    func testOverlappingRunsCannotStealEachOthersModifiedSets() async throws {
        let ids = try makeConversationIDs(count: 4)
        let tracker = ModificationTracker.shared
        let firstRun = await tracker.beginTransaction()
        let secondRun = await tracker.beginTransaction()

        await tracker.trackModifiedConversations([ids[0], ids[1]], in: firstRun)
        await tracker.trackModifiedConversations([ids[2], ids[3]], in: secondRun)

        let firstRunIDs = await tracker.commitTransaction(firstRun)
        await tracker.consumeCommittedTransaction(firstRun)
        let secondRunIDs = await tracker.commitTransaction(secondRun)
        await tracker.consumeCommittedTransaction(secondRun)

        XCTAssertEqual(firstRunIDs, Set([ids[0], ids[1]]))
        XCTAssertEqual(secondRunIDs, Set([ids[2], ids[3]]))
    }

    func testClaimMovesPendingRollupIDsAndEmptiesPendingSet() async throws {
        let ids = try makeConversationIDs(count: 2)
        let tracker = ModificationTracker.shared
        let run = await tracker.beginTransaction()

        await tracker.trackModifiedConversations([ids[0], ids[1]], in: run)

        let claimed = await tracker.claimPendingRollupConversations(in: run)
        let pendingAfterClaim = await tracker.modifiedConversations(in: run)
        let secondClaim = await tracker.claimPendingRollupConversations(in: run)

        XCTAssertEqual(claimed, Set([ids[0], ids[1]]))
        XCTAssertEqual(pendingAfterClaim, [])
        XCTAssertEqual(secondClaim, [])
    }

    func testRetrackingAfterClaimRependsConversationForNextClaim() async throws {
        let ids = try makeConversationIDs(count: 2)
        let tracker = ModificationTracker.shared
        let run = await tracker.beginTransaction()

        await tracker.trackModifiedConversation(ids[0], in: run)
        let firstPageClaim = await tracker.claimPendingRollupConversations(in: run)

        // The same conversation is modified again on a later page alongside a new one.
        await tracker.trackModifiedConversations([ids[0], ids[1]], in: run)
        let secondPageClaim = await tracker.claimPendingRollupConversations(in: run)

        XCTAssertEqual(firstPageClaim, Set([ids[0]]))
        XCTAssertEqual(secondPageClaim, Set([ids[0], ids[1]]))
    }

    func testClaimOnCommittedTransactionReturnsEmptyAndLeavesState() async throws {
        let ids = try makeConversationIDs(count: 1)
        let tracker = ModificationTracker.shared
        let run = await tracker.beginTransaction()

        await tracker.trackModifiedConversation(ids[0], in: run)
        let committedIDs = await tracker.commitTransaction(run)

        let claimAfterCommit = await tracker.claimPendingRollupConversations(in: run)
        let transactionCountAfterClaim = await tracker.transactionCount

        XCTAssertEqual(committedIDs, Set([ids[0]]))
        XCTAssertEqual(claimAfterCommit, [])
        XCTAssertEqual(transactionCountAfterClaim, 1)

        await tracker.consumeCommittedTransaction(run)
    }

    func testCommitReturnsOnlyUnclaimedPendingIDs() async throws {
        let ids = try makeConversationIDs(count: 2)
        let tracker = ModificationTracker.shared
        let run = await tracker.beginTransaction()

        await tracker.trackModifiedConversation(ids[0], in: run)
        _ = await tracker.claimPendingRollupConversations(in: run)
        await tracker.trackModifiedConversation(ids[1], in: run)

        let committedIDs = await tracker.commitTransaction(run)

        XCTAssertEqual(committedIDs, Set([ids[1]]))

        await tracker.consumeCommittedTransaction(run)
    }

    private func makeConversationIDs(count: Int) throws -> [NSManagedObjectID] {
        let stack = TestCoreDataStack()
        let conversations = (0..<count).map { _ in
            ConversationBuilder.simple(in: stack.viewContext)
        }
        try stack.saveViewContext()
        return conversations.map(\.objectID)
    }
}
