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

        let message = try await sendService.createOptimisticMessage(
            to: ["friend@example.com"],
            body: "hello",
            subject: "Subject",
            attachments: try attachmentBuilder.buildSendAttachments(from: [attachment])
        )

        XCTAssertTrue(context.hasChanges, "Optimistic creation should defer persistence so send navigation is not blocked.")
        XCTAssertFalse(message.objectID.isTemporaryID)

        let conversation = try XCTUnwrap(message.conversation)
        XCTAssertFalse(conversation.objectID.isTemporaryID)

        let fetched = try XCTUnwrap(sendService.fetchMessageSync(byID: message.id))
        XCTAssertEqual(fetched.objectID, message.objectID)
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

        let message = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "hello again"
        )

        let conversation = try XCTUnwrap(message.conversation)
        XCTAssertEqual(conversation.objectID, archivedConversation.objectID)
        XCTAssertNil(conversation.archivedAt)
        XCTAssertTrue(context.hasChanges, "Reactivating the conversation and inserting the optimistic message should remain unsaved until the send flow persists it.")
    }
}
