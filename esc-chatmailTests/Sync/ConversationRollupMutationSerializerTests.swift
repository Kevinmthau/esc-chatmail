import CoreData
import XCTest
@testable import esc_chatmail

@MainActor
final class ConversationRollupMutationSerializerTests: XCTestCase {
    func testSyncMutationRestoresNewerReadStateForStaleRegisteredMessage() async throws {
        let stack = TestCoreDataStack()
        let viewContext = stack.viewContext
        let conversation = ConversationBuilder()
            .visible()
            .withUnreadCount(1)
            .build(in: viewContext)
        let inboxLabel = LabelBuilder().inbox().build(in: viewContext)
        let message = MessageBuilder()
            .withId("stale-registered-sync-message")
            .unread()
            .inConversation(conversation)
            .build(in: viewContext)
        message.addToLabels(inboxLabel)
        try stack.saveViewContext()

        let conversationObjectID = conversation.objectID
        let messageObjectID = message.objectID
        let syncContext = stack.newBackgroundContext()
        await syncContext.perform {
            _ = try? syncContext.existingObject(with: conversationObjectID) as? Conversation
            _ = try? syncContext.existingObject(with: messageObjectID) as? Message
        }

        message.isUnread = false
        message.localModifiedAt = Date()
        conversation.inboxUnreadCount = 0
        try stack.saveViewContext()

        let serializer = ConversationRollupMutationSerializer()
        let unreadSeenByRollup = try await serializer.performThrowingSyncMutation(
            conversationIDs: [conversationObjectID],
            in: syncContext
        ) {
            try await syncContext.perform {
                guard let staleConversation = try syncContext.existingObject(
                    with: conversationObjectID
                ) as? Conversation,
                      let staleMessage = try syncContext.existingObject(
                        with: messageObjectID
                      ) as? Message else {
                    throw ConversationRollupMutationSerializerTestError.missingObject
                }

                staleConversation.inboxUnreadCount = staleMessage.isUnread ? 1 : 0
                try syncContext.save()
                return staleMessage.isUnread
            }
        }

        XCTAssertFalse(unreadSeenByRollup)

        let verificationContext = stack.newBackgroundContext()
        let durableState = await verificationContext.perform {
            let durableConversation = try? verificationContext.existingObject(
                with: conversationObjectID
            ) as? Conversation
            let durableMessage = try? verificationContext.existingObject(
                with: messageObjectID
            ) as? Message
            return (durableMessage?.isUnread, durableConversation?.inboxUnreadCount)
        }
        XCTAssertEqual(durableState.0, false)
        XCTAssertEqual(durableState.1, 0)
    }

    func testThrowingMutationReleasesConversationTail() async {
        let serializer = ConversationRollupMutationSerializer()
        let conversationKey = "throwing-sync-mutation"

        do {
            _ = try await serializer.performThrowing(
                conversationKeys: [conversationKey]
            ) { () async throws -> Bool in
                throw ConversationRollupMutationSerializerTestError.expectedFailure
            }
            XCTFail("Expected the serialized operation to throw")
        } catch ConversationRollupMutationSerializerTestError.expectedFailure {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let didRunNextMutation = await serializer.perform(
            conversationKeys: [conversationKey]
        ) {
            true
        }
        XCTAssertTrue(didRunNextMutation)
    }

    func testCancelledQueuedThrowingMutationSkipsOperationAndReleasesConversationTail() async {
        let serializer = ConversationRollupMutationSerializer()
        let conversationKey = "cancelled-sync-mutation"
        let firstMutationStarted = SerializerTestGate()
        let allowFirstMutationToFinish = SerializerTestGate()
        let cancelledMutationProbe = SerializerTestProbe()

        let firstTask = Task {
            await serializer.perform(conversationKeys: [conversationKey]) {
                await firstMutationStarted.open()
                await allowFirstMutationToFinish.wait()
            }
        }
        await firstMutationStarted.wait()

        let cancelledTask = Task {
            try await serializer.performThrowing(
                conversationKeys: [conversationKey]
            ) {
                await cancelledMutationProbe.recordRun()
                return true
            }
        }
        cancelledTask.cancel()

        await allowFirstMutationToFinish.open()
        await firstTask.value

        do {
            _ = try await cancelledTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let cancelledMutationDidRun = await cancelledMutationProbe.didRun()
        XCTAssertFalse(cancelledMutationDidRun)

        let didRunNextMutation = await serializer.perform(
            conversationKeys: [conversationKey]
        ) {
            true
        }
        XCTAssertTrue(didRunNextMutation)
    }

    func testCleanupSensitiveMaintenanceWaitsForOptimisticCreation() async throws {
        let serializer = ConversationRollupMutationSerializer()
        let optimisticCreationStarted = SerializerTestGate()
        let allowOptimisticCreationToFinish = SerializerTestGate()
        let maintenanceWasEnqueued = SerializerTestGate()
        let maintenanceProbe = SerializerTestProbe()

        let optimisticCreation = Task {
            try await serializer.performThrowingCleanupSensitiveMutation {
                await optimisticCreationStarted.open()
                await allowOptimisticCreationToFinish.wait()
                return true
            }
        }
        await optimisticCreationStarted.wait()

        let maintenance = Task {
            await serializer.performCleanupSensitiveMutation(
                onEnqueued: {
                    await maintenanceWasEnqueued.open()
                }
            ) {
                await maintenanceProbe.recordRun()
            }
        }

        // The enqueue callback runs only after maintenance has installed its
        // tail behind the in-flight optimistic transaction. This avoids timing-
        // based assertions while proving the shared key spans an awaited body.
        await maintenanceWasEnqueued.wait()
        let maintenanceRanBeforeOptimisticSave = await maintenanceProbe.didRun()
        XCTAssertFalse(maintenanceRanBeforeOptimisticSave)

        await allowOptimisticCreationToFinish.open()
        let optimisticCreationSucceeded = try await optimisticCreation.value
        XCTAssertTrue(optimisticCreationSucceeded)
        await maintenance.value
        let maintenanceEventuallyRan = await maintenanceProbe.didRun()
        XCTAssertTrue(maintenanceEventuallyRan)
    }
}

private actor SerializerTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}

private actor SerializerTestProbe {
    private var operationDidRun = false

    func recordRun() {
        operationDidRun = true
    }

    func didRun() -> Bool {
        operationDidRun
    }
}

private enum ConversationRollupMutationSerializerTestError: Error {
    case expectedFailure
    case missingObject
}
