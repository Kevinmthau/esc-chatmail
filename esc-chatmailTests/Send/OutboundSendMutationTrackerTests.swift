import XCTest
@testable import esc_chatmail

@MainActor
final class OutboundSendMutationTrackerTests: XCTestCase {
    func testTrackPendingMutationAndReconcileSuccess_clearsPendingState() {
        let tracker = OutboundSendMutationTracker()
        let conversationReference = ConversationReference(
            persistentStoreURI: URL(string: "x-coredata://conversation/123")!
        )

        tracker.trackPendingMutation(
            .init(
                optimisticMessageID: "optimistic-1",
                conversationReference: conversationReference
            )
        )

        XCTAssertEqual(tracker.pendingMutationCount, 1)
        XCTAssertTrue(tracker.failedMutations.isEmpty)

        tracker.reconcileSuccess(
            .init(
                optimisticMessageID: "optimistic-1",
                sentMessageID: "sent-1",
                threadID: "thread-1"
            )
        )

        XCTAssertEqual(tracker.pendingMutationCount, 0)
        XCTAssertTrue(tracker.failedMutations.isEmpty)
    }

    func testReconcileFailure_carriesConversationReferenceIntoFailedMutation() {
        let tracker = OutboundSendMutationTracker()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let conversationReference = ConversationReference(
            persistentStoreURI: URL(string: "x-coredata://conversation/456")!
        )

        tracker.trackPendingMutation(
            .init(
                optimisticMessageID: "optimistic-2",
                conversationReference: conversationReference,
                createdAt: createdAt
            )
        )

        tracker.reconcileFailure(
            .init(
                optimisticMessageID: "optimistic-2",
                errorDescription: "boom"
            )
        )

        XCTAssertEqual(tracker.pendingMutationCount, 0)
        guard let failedMutation = tracker.failedMutations.first else {
            return XCTFail("Expected failed mutation")
        }
        XCTAssertEqual(failedMutation.id, "optimistic-2")
        XCTAssertEqual(failedMutation.conversationReference, conversationReference)
        XCTAssertEqual(failedMutation.createdAt, createdAt)
        XCTAssertEqual(failedMutation.errorDescription, "boom")
    }

    func testReconcileAmbiguous_clearsPendingWithoutRecordingFailure() {
        let tracker = OutboundSendMutationTracker()
        tracker.trackPendingMutation(
            .init(
                optimisticMessageID: "optimistic-ambiguous",
                conversationReference: nil
            )
        )

        tracker.reconcileAmbiguous(
            .init(optimisticMessageID: "optimistic-ambiguous")
        )

        XCTAssertEqual(tracker.pendingMutationCount, 0)
        XCTAssertTrue(tracker.failedMutations.isEmpty)
    }
}
