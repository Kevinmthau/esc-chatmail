import XCTest
import CoreData
@testable import esc_chatmail

final class ConversationUpdatePhaseTests: XCTestCase {
    override func tearDown() async throws {
        await ModificationTracker.shared.reset()
        try await super.tearDown()
    }

    func testExecute_passesCommittedModifiedIDsToRollupUpdater() async throws {
        let stack = TestCoreDataStack()
        let expectedIDs = try makeConversationIDs(count: 2, in: stack)
        let transaction = await ModificationTracker.shared.beginTransaction()
        let context = SyncPhaseContext(
            coreDataContext: stack.newBackgroundContext(),
            labelIds: [],
            myAliases: [],
            modificationTransaction: transaction,
            syncStartTime: Date(),
            progressHandler: { _, _ in },
            failureTracker: .shared
        )

        let didUpdate = expectation(description: "rollups updated")
        var capturedIDs: Set<NSManagedObjectID> = []
        var capturedContextID: ObjectIdentifier?

        let phase = ConversationUpdatePhase { conversationIDs, rollupContext in
            capturedIDs = conversationIDs
            capturedContextID = ObjectIdentifier(rollupContext)
            didUpdate.fulfill()
        }

        try await phase.execute(input: expectedIDs, context: context)
        await fulfillment(of: [didUpdate], timeout: 1.0)

        XCTAssertEqual(capturedIDs, expectedIDs)
        XCTAssertEqual(capturedContextID, ObjectIdentifier(context.coreDataContext))
    }

    private func makeConversationIDs(
        count: Int,
        in stack: TestCoreDataStack
    ) throws -> Set<NSManagedObjectID> {
        let conversations = (0..<count).map { _ in
            ConversationBuilder.simple(in: stack.viewContext)
        }
        try stack.saveViewContext()
        return Set(conversations.map(\.objectID))
    }
}
