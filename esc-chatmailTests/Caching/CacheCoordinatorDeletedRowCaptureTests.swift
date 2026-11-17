import XCTest
import CoreData
@testable import esc_chatmail

/// What `CacheCoordinator` learns from a save that deleted rows, on a SQLite store, where a
/// deleted row is really gone after the save.
///
/// Before scalability review step 7 the coordinator kept the deleted objects' IDs, crossed to
/// the main queue and resolved them again. An ID of a committed delete resolves to a tombstone
/// (nil `id`, nil paths, no attachments), so the plan was empty for every delete and no body
/// or attachment file of a deleted message was removed until the daily orphan sweeps ran.
///
/// The context is a main-queue one (`makeMainQueueViewContext`) and the class is
/// `@MainActor`, so the saves, and the notifications they post, are on the context's queue.
@MainActor
final class CacheCoordinatorDeletedRowCaptureTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack(storeKind: .sqlite)
        context = stack.makeMainQueueViewContext()
    }

    override func tearDown() {
        context = nil
        stack = nil
        super.tearDown()
    }

    // Revert-check: `CacheCoordinator.invalidationPlan(forSave:)` reading the instances under
    // `NSDeletedObjectsKey`. Build the plan from the deleted objects' IDs after the save
    // (`context.object(with:)`), as before, and every assertion on the plan fails: the
    // second half of this test shows what those IDs resolve to.
    func testSavedDelete_planReadInsideTheSaveNotification_carriesIdBodyURIAndAttachmentPaths() throws {
        let messageId = "deleted-\(UUID().uuidString)"
        let bodyStorageURI = "/tmp/elsewhere/\(messageId).html"
        let message = MessageBuilder().withId(messageId).build(in: context)
        message.bodyStorageURI = bodyStorageURI
        _ = AttachmentBuilder()
            .withId("att-1")
            .withLocalURL("Attachments/\(messageId).jpg")
            .withPreviewURL("Previews/\(messageId).jpg")
            .forMessage(message)
            .build(in: context)
        try context.save()
        let messageObjectID = message.objectID

        let plan = try planReadWhileSaving {
            context.delete(message)
        }

        XCTAssertEqual(plan.messageIdsToInvalidate, [messageId])
        XCTAssertEqual(
            plan.deletedHTMLArtifacts,
            [DeletedMessageBody(messageId: messageId, bodyStorageURI: bodyStorageURI)]
        )
        XCTAssertEqual(
            plan.attachmentPathsToDelete,
            ["Attachments/\(messageId).jpg", "Previews/\(messageId).jpg"]
        )
        XCTAssertEqual(plan.attachmentIdentitiesToInvalidate.map(\.attachmentId), ["att-1"])

        // What the plan was built from before: the same row, asked for by its ID once the
        // save has returned. Read on a context that never held the row.
        let later = stack.makeMainQueueViewContext()
        let tombstone = try XCTUnwrap(later.object(with: messageObjectID) as? Message)
        XCTAssertNil(
            tombstone.value(forKey: "id") as? String,
            "An ID of a committed delete names no row: it resolves to an object with no values"
        )
        XCTAssertNil(tombstone.value(forKey: "bodyStorageURI") as? String)
    }

    // Revert-check: the deleted-`Person` branch of `computeInvalidationPlan`, which reads the
    // email off the deleted instance and never sets `shouldClearPersonCache`. As it was
    // before, with the deleted Person resolved from its ID and a missing email clearing the
    // whole cache as it does for an updated one, both assertions fail.
    func testSavedDeleteOfAPerson_evictsThatAddressAndDoesNotClearTheCache() throws {
        let person = PersonBuilder().withEmail("gone@example.com").build(in: context)
        try context.save()

        let plan = try planReadWhileSaving {
            context.delete(person)
        }

        XCTAssertEqual(plan.personEmailsToInvalidate, ["gone@example.com"])
        XCTAssertFalse(plan.shouldClearPersonCache)
    }

    // Revert-check, two of them.
    // 1. `invalidationPlan(forSave:)`, which the `compactMap` in `CacheCoordinator.start`
    //    calls while the save is posted, reading the deleted instances. Resolve their IDs
    //    instead and the plan is empty, the removers are never called, and the wait below
    //    times out.
    // 2. `deleteMessageBodiesOffMainActor`. Call `fileReclamation.deleteMessageBodies` in
    //    `performAsyncInvalidation` itself, which is main-actor, and the recorder is called
    //    on the main thread.
    func testStartedCoordinator_savedDelete_handsTheFilesToTheRemoversOffTheMainThread() async throws {
        let messageId = "deleted-\(UUID().uuidString)"
        let message = MessageBuilder().withId(messageId).build(in: context)
        _ = AttachmentBuilder()
            .withId("att-1")
            .withLocalURL("Attachments/\(messageId).jpg")
            .forMessage(message)
            .build(in: context)
        try context.save()

        let removals = RemovalRecorder()
        let coordinator = CacheCoordinator(
            fileReclamation: CacheCoordinator.FileReclamation(
                deleteMessageBodies: { bodies, deletedAt, _ in
                    removals.recordBodies(bodies, deletedAt: deletedAt, onMainThread: Thread.isMainThread)
                },
                deleteAttachmentFiles: { paths, _, _ in
                    removals.recordAttachmentPaths(paths)
                }
            )
        )
        coordinator.start(observing: context)
        defer { coordinator.stop() }
        let beforeDelete = Date()

        context.delete(message)
        try context.save()
        let afterSave = Date()

        let handedOver = await waitUntil(timeout: 5) {
            !removals.bodies.isEmpty && !removals.attachmentPaths.isEmpty
        }
        XCTAssertTrue(handedOver, "The deleted message's files never reached the removers")
        XCTAssertEqual(removals.bodies, [DeletedMessageBody(messageId: messageId, bodyStorageURI: nil)])
        XCTAssertEqual(removals.attachmentPaths, ["Attachments/\(messageId).jpg"])
        XCTAssertEqual(removals.bodiesWereRemovedOnMainThread, false)
        // The time the removers compare a file's date with is the save's, not the removal's.
        let deletedAt = try XCTUnwrap(removals.deletedAt)
        XCTAssertGreaterThanOrEqual(deletedAt, beforeDelete)
        XCTAssertLessThanOrEqual(deletedAt, afterSave)
        await coordinator.closeAccountWorkAndAwait()
    }

    /// Saves `change` and returns the plan `CacheCoordinator` reads for that save, read as
    /// the coordinator reads it: synchronously, while the notification is being posted.
    private func planReadWhileSaving(
        _ change: () -> Void
    ) throws -> CacheCoordinator.CacheInvalidationPlan {
        var plan: CacheCoordinator.CacheInvalidationPlan?
        let observer = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: context,
            queue: nil
        ) { notification in
            plan = CacheCoordinator.invalidationPlan(forSave: notification)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        change()
        try context.save()
        return try XCTUnwrap(plan, "The save posted no notification")
    }

    private func waitUntil(
        timeout: TimeInterval,
        pollIntervalNanoseconds: UInt64 = 5_000_000,
        condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        return await condition()
    }
}

private final class RemovalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedBodies: [DeletedMessageBody] = []
    private var recordedPaths: [String] = []
    private var recordedMainThread: Bool?
    private var recordedDeletedAt: Date?

    var deletedAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return recordedDeletedAt
    }

    func recordBodies(_ bodies: [DeletedMessageBody], deletedAt: Date, onMainThread: Bool) {
        lock.lock()
        defer { lock.unlock() }
        recordedBodies.append(contentsOf: bodies)
        recordedDeletedAt = deletedAt
        recordedMainThread = (recordedMainThread ?? false) || onMainThread
    }

    func recordAttachmentPaths(_ paths: [String]) {
        lock.lock()
        defer { lock.unlock() }
        recordedPaths.append(contentsOf: paths)
    }

    var bodies: [DeletedMessageBody] {
        lock.lock()
        defer { lock.unlock() }
        return recordedBodies
    }

    var attachmentPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPaths
    }

    var bodiesWereRemovedOnMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return recordedMainThread
    }
}
