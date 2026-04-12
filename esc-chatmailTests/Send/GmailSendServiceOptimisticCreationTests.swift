import XCTest
@testable import esc_chatmail

@MainActor
final class GmailSendServiceOptimisticCreationTests: XCTestCase {
    private var coreDataStack: TestCoreDataStack!
    private var sendService: GmailSendService!

    override func setUp() {
        super.setUp()
        coreDataStack = TestCoreDataStack()
        sendService = GmailSendService(viewContext: coreDataStack.viewContext)
    }

    override func tearDown() {
        coreDataStack?.resetViewContext()
        sendService = nil
        coreDataStack = nil
        super.tearDown()
    }

    func testCreateOptimisticMessage_newConversationLeavesChangesPendingWithStableIDs() async throws {
        let context = coreDataStack.viewContext
        let attachmentBuilder = OutboundAttachmentContextBuilder(viewContext: context)
        let attachment = AttachmentBuilder()
            .withId("local_attachment_1")
            .asImage()
            .queued()
            .withLocalURL("Attachments/photo.jpg")
            .withPreviewURL("Previews/photo.jpg")
            .build(in: context)

        let handle = try await sendService.createOptimisticMessage(
            to: ["friend@example.com"],
            body: "hello",
            subject: "Subject",
            attachments: try attachmentBuilder.buildSendAttachments(from: [attachment]),
            optimisticConversation: .participantHash(
                calculateParticipantHash(from: [normalizedEmail("friend@example.com")])
            )
        )

        XCTAssertTrue(context.hasChanges, "Optimistic creation should defer persistence so send navigation is not blocked.")
        let fetched = try XCTUnwrap(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertFalse(fetched.objectID.isTemporaryID)

        let conversation = try XCTUnwrap(fetched.conversation)
        XCTAssertFalse(conversation.objectID.isTemporaryID)
        XCTAssertEqual(handle.conversationReference, ConversationReference(objectID: conversation.objectID))

        XCTAssertEqual(fetched.attachmentsArray.compactMap(\.id), ["local_attachment_1"])
    }

    func testCreateOptimisticMessage_reactivatesArchivedConversationWithoutImmediateSave() async throws {
        let context = coreDataStack.viewContext
        let recipient = "friend@example.com"
        let participantHash = calculateParticipantHash(from: [normalizedEmail(recipient)])

        let archivedConversation = ConversationBuilder()
            .withParticipantHash(participantHash)
            .withDisplayName("Archived")
            .archived()
            .build(in: context)
        try coreDataStack.saveViewContext()

        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "hello again",
            optimisticConversation: .participantHash(participantHash)
        )

        let message = try XCTUnwrap(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        let conversation = try XCTUnwrap(message.conversation)
        XCTAssertEqual(conversation.objectID, archivedConversation.objectID)
        XCTAssertEqual(handle.conversationReference, ConversationReference(objectID: conversation.objectID))
        XCTAssertNil(conversation.archivedAt)
        XCTAssertTrue(context.hasChanges, "Reactivating the conversation and inserting the optimistic message should remain unsaved until the send flow persists it.")
    }

    func testCreateOptimisticMessage_withOptimisticConversationReferenceReusesExistingConversation() async throws {
        let context = coreDataStack.viewContext
        let conversation = ConversationBuilder()
            .withDisplayName("Reply Thread")
            .visible()
            .recentlyActive()
            .build(in: context)
        try coreDataStack.saveViewContext()

        let handle = try await sendService.createOptimisticMessage(
            to: ["friend@example.com"],
            body: "anchored reply",
            subject: "Re: Hello",
            threadId: "thread-123",
            optimisticConversation: .existingConversation(ConversationReference(objectID: conversation.objectID))
        )

        let message = try XCTUnwrap(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertEqual(message.conversation?.objectID, conversation.objectID)
        XCTAssertEqual(handle.conversationReference, ConversationReference(objectID: conversation.objectID))
        XCTAssertEqual(message.gmThreadId, "thread-123")
        XCTAssertTrue(context.hasChanges, "Anchored optimistic replies should stay unsaved until the background send path persists them.")
    }
}
