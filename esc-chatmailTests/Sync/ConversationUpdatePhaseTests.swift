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
        let recorder = RollupUpdateRecorder()

        let phase = ConversationUpdatePhase { conversationIDs, rollupContext in
            await recorder.record(conversationIDs: conversationIDs, context: rollupContext)
            didUpdate.fulfill()
        }

        try await phase.execute(input: expectedIDs, context: context)
        await fulfillment(of: [didUpdate], timeout: 1.0)

        let captured = await recorder.snapshot()
        XCTAssertEqual(captured.conversationIDs, expectedIDs)
        XCTAssertEqual(captured.contextID, ObjectIdentifier(context.coreDataContext))
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

private actor RollupUpdateRecorder {
    private var conversationIDs: Set<NSManagedObjectID> = []
    private var contextID: ObjectIdentifier?

    func record(conversationIDs: Set<NSManagedObjectID>, context: NSManagedObjectContext) {
        self.conversationIDs = conversationIDs
        self.contextID = ObjectIdentifier(context)
    }

    func snapshot() -> (conversationIDs: Set<NSManagedObjectID>, contextID: ObjectIdentifier?) {
        (conversationIDs, contextID)
    }
}
