import XCTest
import CoreData
@testable import esc_chatmail

/// The deletion and label mutation paths must THROW on Core Data failure
/// instead of returning empty results: a swallowed error there is
/// indistinguishable from "nothing to do", which lets the cursor advance past
/// deletions and label changes that were never applied.
final class HistoryMutationFailureTests: XCTestCase {

    /// A context whose fetches throw at the store level, deterministically
    /// simulating a Core Data read failure (a store-less coordinator would
    /// return [] silently).
    private func makeStorelessContext() throws -> NSManagedObjectContext {
        try FailingReadStore.makeFailingContext()
    }

    func testProcessMessageDeletionsThrowsOnFetchFailure() async throws {
        let context = try makeStorelessContext()
        let processor = HistoryProcessor()

        do {
            try await processor.processMessageDeletions(
                [HistoryMessageDeleted(message: MessageListItem(id: "doomed", threadId: nil))],
                modificationTransaction: nil,
                in: context
            )
            XCTFail("A lost deletion must surface as an error, not silence")
        } catch {
            // Expected: the run aborts and the cursor stays put.
        }
    }

    func testLabelOperationProcessorThrowsOnFetchFailure() async throws {
        let context = try makeStorelessContext()

        do {
            _ = try await LabelOperationProcessor.process(
                items: [
                    HistoryLabelAdded(
                        message: MessageListItem(id: "doomed", threadId: nil),
                        labelIds: ["TRASH"]
                    )
                ],
                operation: .add,
                in: context,
                syncStartTime: nil
            )
            XCTFail("Dropped label mutations must surface as an error, not an empty result")
        } catch {
            // Expected.
        }
    }

    func testLightweightOperationsPropagateDeletionFailure() async throws {
        let context = try makeStorelessContext()
        let processor = HistoryProcessor()
        let record = HistoryRecord(
            id: "h1",
            messages: nil,
            messagesAdded: nil,
            messagesDeleted: [HistoryMessageDeleted(message: MessageListItem(id: "doomed", threadId: nil))],
            labelsAdded: nil,
            labelsRemoved: nil
        )

        do {
            try await processor.processLightweightOperations(
                record,
                in: context,
                modificationTransaction: nil
            )
            XCTFail("Deletion failure must propagate through the lightweight-operations path")
        } catch {
            // Expected.
        }
    }
}
