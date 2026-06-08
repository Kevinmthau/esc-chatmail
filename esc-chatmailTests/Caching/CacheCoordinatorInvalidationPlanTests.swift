import XCTest
import CoreData
@testable import esc_chatmail

/// Characterization tests for `CacheCoordinator.computeInvalidationPlan`.
///
/// These pin the CURRENT cache-invalidation contract: given a set of updated /
/// deleted Core Data object IDs, which caches the coordinator decides to
/// invalidate. They exercise the pure, synchronous planning function directly,
/// so they are fully deterministic — no global `NSManagedObjectContextDidSave`
/// notification, no async draining, no shared-singleton state.
///
/// They intentionally also document KNOWN GAPS that the cache-consolidation
/// work is expected to change later (for example: an *updated* message does not
/// invalidate rendered-text / HTML caches today, and `RenderedMessageCache` /
/// full-email WebView artifacts are not represented in the plan at all). When
/// that behavior changes on purpose, update the corresponding test deliberately
/// rather than loosening it.
final class CacheCoordinatorInvalidationPlanTests: XCTestCase {

    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        context = stack.viewContext
    }

    override func tearDown() {
        context = nil
        stack = nil
        super.tearDown()
    }

    /// Runs the planning function on the context's queue, mirroring how
    /// `handleContextDidSave` invokes it inside `sourceContext.perform`.
    private func computePlan(
        updated: [NSManagedObject] = [],
        deleted: [NSManagedObject] = []
    ) -> CacheCoordinator.CacheInvalidationPlan {
        var plan = CacheCoordinator.CacheInvalidationPlan()
        context.performAndWait {
            plan = CacheCoordinator.computeInvalidationPlan(
                updatedObjectIDs: Set(updated.map(\.objectID)),
                deletedObjectIDs: Set(deleted.map(\.objectID)),
                in: context
            )
        }
        return plan
    }

    // MARK: - Messages

    func testDeletedMessage_invalidatesMessageIdAndHTMLArtifact() {
        let message = MessageBuilder().withId("msg-1").build(in: context)

        let plan = computePlan(deleted: [message])

        XCTAssertEqual(plan.messageIdsToInvalidate, ["msg-1"])
        XCTAssertEqual(
            plan.deletedHTMLArtifacts,
            [CacheCoordinator.CacheInvalidationPlan.DeletedHTMLArtifact(
                messageId: "msg-1",
                bodyStorageURI: nil
            )]
        )
    }

    func testDeletedMessageWithAttachments_collectsAttachmentPathsAndIds() {
        let message = MessageBuilder().withId("msg-2").build(in: context)
        _ = AttachmentBuilder()
            .withId("att-1")
            .withLocalURL("Attachments/a.jpg")
            .withPreviewURL("Previews/a.jpg")
            .forMessage(message)
            .build(in: context)

        let plan = computePlan(deleted: [message])

        XCTAssertTrue(plan.attachmentPathsToDelete.contains("Attachments/a.jpg"))
        XCTAssertTrue(plan.attachmentPathsToDelete.contains("Previews/a.jpg"))
        XCTAssertTrue(plan.attachmentIdsToInvalidate.contains("att-1"))
    }

    /// GAP: an *updated* (not deleted) message does not invalidate rendered-text
    /// or HTML caches today, so a re-synced/edited message can serve stale
    /// rendered content. Cache consolidation is expected to close this — update
    /// this test deliberately when it does.
    func testUpdatedMessage_doesNotInvalidateMessageCaches() {
        let message = MessageBuilder().withId("msg-3").build(in: context)

        let plan = computePlan(updated: [message])

        XCTAssertTrue(plan.messageIdsToInvalidate.isEmpty)
        XCTAssertTrue(plan.deletedHTMLArtifacts.isEmpty)
    }

    // MARK: - Conversations

    func testUpdatedConversation_invalidatesConversationId() {
        let id = UUID()
        let conversation = ConversationBuilder().withId(id).build(in: context)

        let plan = computePlan(updated: [conversation])

        XCTAssertEqual(plan.conversationIdsToInvalidate, [id.uuidString])
        XCTAssertFalse(plan.shouldClearConversationCache)
    }

    func testDeletedConversation_invalidatesConversationId() {
        let id = UUID()
        let conversation = ConversationBuilder().withId(id).build(in: context)

        let plan = computePlan(deleted: [conversation])

        XCTAssertEqual(plan.conversationIdsToInvalidate, [id.uuidString])
        XCTAssertFalse(plan.shouldClearConversationCache)
    }

    // MARK: - People

    func testUpdatedPerson_invalidatesEmail() {
        let person = PersonBuilder().withEmail("alice@example.com").build(in: context)

        let plan = computePlan(updated: [person])

        XCTAssertEqual(plan.personEmailsToInvalidate, ["alice@example.com"])
        XCTAssertFalse(plan.shouldClearPersonCache)
    }

    /// A Person whose email is missing/empty cannot be invalidated precisely, so
    /// the coordinator falls back to clearing the entire PersonCache.
    func testPersonWithEmptyEmail_requestsFullPersonCacheClear() {
        let person = PersonBuilder().withEmail("").build(in: context)

        let plan = computePlan(updated: [person])

        XCTAssertTrue(plan.shouldClearPersonCache)
        XCTAssertTrue(plan.personEmailsToInvalidate.isEmpty)
    }

    // MARK: - Attachments (standalone delete)

    func testDeletedAttachment_collectsPathsAndId() {
        let attachment = AttachmentBuilder()
            .withId("att-2")
            .withLocalURL("Attachments/b.pdf")
            .withPreviewURL("Previews/b.png")
            .build(in: context)

        let plan = computePlan(deleted: [attachment])

        XCTAssertTrue(plan.attachmentPathsToDelete.contains("Attachments/b.pdf"))
        XCTAssertTrue(plan.attachmentPathsToDelete.contains("Previews/b.png"))
        XCTAssertTrue(plan.attachmentIdsToInvalidate.contains("att-2"))
    }

    /// GAP: an *updated* attachment (e.g. download state change) is not acted on
    /// — only deletes reclaim attachment files/cache entries.
    func testUpdatedAttachment_isNotCollected() {
        let attachment = AttachmentBuilder()
            .withId("att-3")
            .withLocalURL("Attachments/c.jpg")
            .build(in: context)

        let plan = computePlan(updated: [attachment])

        XCTAssertTrue(plan.attachmentPathsToDelete.isEmpty)
        XCTAssertTrue(plan.attachmentIdsToInvalidate.isEmpty)
    }

    // MARK: - Mixed / empty

    func testMixedChanges_areAllRepresentedInOnePlan() {
        let conversationId = UUID()
        let conversation = ConversationBuilder().withId(conversationId).build(in: context)
        let person = PersonBuilder().withEmail("bob@example.com").build(in: context)
        let message = MessageBuilder().withId("msg-mixed").build(in: context)

        let plan = computePlan(updated: [conversation, person], deleted: [message])

        XCTAssertEqual(plan.conversationIdsToInvalidate, [conversationId.uuidString])
        XCTAssertEqual(plan.personEmailsToInvalidate, ["bob@example.com"])
        XCTAssertEqual(plan.messageIdsToInvalidate, ["msg-mixed"])
    }

    func testNoChanges_producesEmptyPlan() {
        let plan = computePlan()

        XCTAssertTrue(plan.conversationIdsToInvalidate.isEmpty)
        XCTAssertTrue(plan.personEmailsToInvalidate.isEmpty)
        XCTAssertTrue(plan.messageIdsToInvalidate.isEmpty)
        XCTAssertTrue(plan.deletedHTMLArtifacts.isEmpty)
        XCTAssertTrue(plan.attachmentPathsToDelete.isEmpty)
        XCTAssertTrue(plan.attachmentIdsToInvalidate.isEmpty)
        XCTAssertFalse(plan.shouldClearConversationCache)
        XCTAssertFalse(plan.shouldClearPersonCache)
    }
}
