import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class ChatMessageRowModelTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var viewContext: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        viewContext = stack.viewContext
    }

    override func tearDown() {
        viewContext = nil
        stack = nil
        super.tearDown()
    }

    func testMap_usesParticipantFallbacksAndAttachmentSnapshots() throws {
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: viewContext)
        let sender = PersonBuilder()
            .withEmail("participant@example.com")
            .withDisplayName("Participant Person")
            .withAvatarURL("file:///avatar.png")
            .build(in: viewContext)
        let message = MessageBuilder()
            .withId("row-model-participant-fallback")
            .withSender(email: "", name: "Header Sender")
            .withSubject("Subject")
            .withSnippet("Snippet")
            .withAttachments()
            .inConversation(conversation)
            .build(in: viewContext)
        message.cleanedSnippet = "Cleaned Snippet"
        message.chatPreviewText = "Chat preview\n\nText"

        let participant = MessageParticipant(context: viewContext)
        participant.id = UUID()
        participant.participantKind = .from
        participant.message = message
        participant.person = sender

        let attachment = Attachment(context: viewContext)
        attachment.id = "attachment-1"
        attachment.contentId = "cid-attachment-1"
        attachment.filename = "photo.png"
        attachment.mimeType = "image/png"
        attachment.stateRaw = Attachment.State.downloaded.rawValue
        attachment.localURL = "Attachments/photo.png"
        attachment.previewURL = "Previews/photo.png"
        attachment.byteSize = 1_024
        attachment.width = 200
        attachment.height = 180
        attachment.message = message

        try viewContext.obtainPermanentIDs(for: [message, participant, attachment])
        try viewContext.save()

        let row = ChatMessageRowModelMapper.map(message)

        XCTAssertEqual(row.id, "row-model-participant-fallback")
        XCTAssertEqual(row.messageObjectID, message.objectID)
        XCTAssertEqual(row.conversationObjectID, conversation.objectID)
        XCTAssertNil(row.senderEmail)
        XCTAssertEqual(row.effectiveSenderEmail, "participant@example.com")
        XCTAssertEqual(row.senderGroupingKeyInput, "participant@example.com")
        XCTAssertEqual(row.senderInfoEmail, "participant@example.com")
        XCTAssertEqual(row.senderInfoDisplayName, "Participant Person")
        XCTAssertEqual(row.senderInfoAvatarURL, "file:///avatar.png")
        XCTAssertEqual(row.fallbackPreviewText, "Cleaned Snippet")
        XCTAssertEqual(row.chatPreviewText, "Chat preview\n\nText")
        XCTAssertEqual(row.attachments.count, 1)
        XCTAssertEqual(row.attachments.first?.objectID, attachment.objectID)
        XCTAssertEqual(row.attachments.first?.previewURL, "Previews/photo.png")
        let contentRequest = row.makeContentRequest()
        XCTAssertEqual(contentRequest.chatPreviewText, "Chat preview\n\nText")
        XCTAssertEqual(contentRequest.attachmentSnapshots.count, 1)
    }

    func testMap_preservesOutgoingForwardedAffordances() throws {
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: viewContext)
        let message = MessageBuilder()
            .withId("row-model-forwarded")
            .withSender(email: "me@example.com", name: "Me")
            .withSubject("Fwd: Spring plans")
            .withSnippet("FYI ---------- Forwarded message --------- From: Jane Example")
            .withBody(
                """
                FYI

                ---------- Forwarded message ---------
                From: Jane Example <jane@example.com>
                Date: Mon, Feb 16, 2026 at 5:56 PM
                Subject: Spring plans
                To: me@example.com

                Looking forward to seeing you there.
                """
            )
            .withAttachments()
            .fromMe()
            .inConversation(conversation)
            .build(in: viewContext)

        let failedAttachment = Attachment(context: viewContext)
        failedAttachment.id = "local_failed_attachment"
        failedAttachment.filename = "agenda.pdf"
        failedAttachment.mimeType = "application/pdf"
        failedAttachment.stateRaw = Attachment.State.failed.rawValue
        failedAttachment.message = message

        try viewContext.obtainPermanentIDs(for: [message, failedAttachment])
        try viewContext.save()

        let row = ChatMessageRowModelMapper.map(message)

        XCTAssertTrue(row.isFromMe)
        XCTAssertTrue(row.isForwardedEmail)
        XCTAssertEqual(row.forwardedDisplaySubject, "Spring plans")
        XCTAssertEqual(row.outgoingForwardedDisplayContent?.subject, "Spring plans")
        XCTAssertEqual(
            row.outgoingForwardedDisplayContent?.previewSnippet,
            "Looking forward to seeing you there."
        )
        XCTAssertTrue(row.hasFailedLocalAttachmentUploads)
        XCTAssertFalse(row.isSendingLocalAttachments)
        XCTAssertNil(row.makeSenderRequest())
    }
}
