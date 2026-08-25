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

        let participant = viewContext.insertTestObject(MessageParticipant.self)
        participant.id = UUID()
        participant.participantKind = .from
        participant.message = message
        participant.person = sender

        let attachment = viewContext.insertTestObject(Attachment.self)
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

    func testMap_suppressesQuoteOnlyFallbackForOutgoingAttachmentOnlyMessage() throws {
        let quoteOnlySnippet = "On Aug 24, 2026 at 5:47 PM, Kelsey Conroy wrote: Yes, I can&#39;t view the PDF though."
        let message = MessageBuilder()
            .withId("row-model-attachment-only-reply")
            .withSnippet(quoteOnlySnippet)
            .withAttachments()
            .fromMe()
            .build(in: viewContext)
        message.cleanedSnippet = quoteOnlySnippet

        let row = ChatMessageRowModelMapper.map(message)

        XCTAssertNil(row.chatPreviewText)
        XCTAssertNil(row.fallbackPreviewText)
    }

    func testMap_preservesAuthoredFallbackForOutgoingMessageWithAttachments() throws {
        let message = MessageBuilder()
            .withId("row-model-attachment-reply-with-text")
            .withSnippet("Here are the two PDFs.")
            .withAttachments()
            .fromMe()
            .build(in: viewContext)
        message.cleanedSnippet = "Here are the two PDFs."

        let row = ChatMessageRowModelMapper.map(message)

        XCTAssertEqual(row.fallbackPreviewText, "Here are the two PDFs.")
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

        let failedAttachment = viewContext.insertTestObject(Attachment.self)
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

    func testMap_buildsSenderRequestFromHeaderWhenFromParticipantIsMissing() throws {
        let message = MessageBuilder()
            .withId("row-model-header-sender")
            .withSender(email: "sender@example.com", name: "Header Sender")
            .build(in: viewContext)
        try viewContext.obtainPermanentIDs(for: [message])
        try viewContext.save()

        let row = ChatMessageRowModelMapper.map(message)
        let request = try XCTUnwrap(row.makeSenderRequest())

        XCTAssertEqual(request.email, "sender@example.com")
        XCTAssertEqual(request.headerDisplayName, "Header Sender")
        XCTAssertNil(request.personDisplayName)
    }

    func testMap_surfacesDurableOutboundDeliveryStates() throws {
        let optimisticID = UUID().uuidString
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: viewContext)
        let message = MessageBuilder()
            .withId(optimisticID)
            .withBody("Preserved user-authored text")
            .fromMe()
            .inConversation(conversation)
            .build(in: viewContext)
        message.messageId = MimeBuilder.messageId(
            forOptimisticMessageID: optimisticID
        )
        let record = viewContext.insertTestObject(OutboundSendMutationRecord.self)
        record.id = optimisticID
        record.createdAt = Date()
        try viewContext.save()

        XCTAssertEqual(
            ChatMessageRowModelMapper.map(message).outboundSendDeliveryState,
            .sending
        )

        record.remoteCommittedMessageId = OutboundSendRemoteState.inFlightMessageID
        try viewContext.save()
        XCTAssertEqual(
            ChatMessageRowModelMapper.map(message).outboundSendDeliveryState,
            .sending
        )

        record.remoteCommittedMessageId = OutboundSendRemoteState.notSentMessageID
        try viewContext.save()
        XCTAssertEqual(
            ChatMessageRowModelMapper.map(message).outboundSendDeliveryState,
            .notSent
        )

        record.remoteCommittedMessageId = OutboundSendRemoteState.ambiguousMessageID
        try viewContext.save()
        XCTAssertEqual(
            ChatMessageRowModelMapper.map(message).outboundSendDeliveryState,
            .deliveryUnknown
        )
    }

    func testMapMessages_batchFetchesOutboundDeliveryStateOnceForMultipleRows() throws {
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: viewContext)
        let stateMarkers: [String?] = [
            nil,
            OutboundSendRemoteState.notSentMessageID,
            OutboundSendRemoteState.ambiguousMessageID
        ]
        var messages: [Message] = []
        var optimisticIDs = Set<String>()

        for marker in stateMarkers {
            let optimisticID = UUID().uuidString
            optimisticIDs.insert(optimisticID)
            let message = MessageBuilder()
                .withId(optimisticID)
                .withBody("Preserved body \(optimisticID)")
                .fromMe()
                .inConversation(conversation)
                .build(in: viewContext)
            message.messageId = MimeBuilder.messageId(
                forOptimisticMessageID: optimisticID
            )
            let record = viewContext.insertTestObject(OutboundSendMutationRecord.self)
            record.id = optimisticID
            record.createdAt = Date()
            record.remoteCommittedMessageId = marker
            messages.append(message)
        }

        let ordinaryMessage = MessageBuilder()
            .withId("gmail-ordinary-sent-row")
            .fromMe()
            .inConversation(conversation)
            .build(in: viewContext)
        ordinaryMessage.messageId = "<ordinary@example.com>"
        messages.append(ordinaryMessage)
        try viewContext.save()

        var fetchCount = 0
        var requestedIDs = Set<String>()
        let rows = ChatMessageRowModelMapper.map(
            messages,
            fetchOutboundSendMutationRecords: { context, ids in
                fetchCount += 1
                requestedIDs.formUnion(ids)
                let request = OutboundSendMutationRecord.fetchRequest()
                request.predicate = NSPredicate(format: "id IN %@", Array(ids))
                request.includesPendingChanges = true
                return try context.fetch(request)
            }
        )

        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(requestedIDs, optimisticIDs)
        XCTAssertEqual(
            rows.map(\.outboundSendDeliveryState),
            [.sending, .notSent, .deliveryUnknown, .none]
        )
    }

    func testMessageSendStatusPresentation_pinsLabelsAndPrioritizesDurableState() {
        XCTAssertEqual(
            MessageSendStatusPresentation.resolve(
                deliveryState: .sending,
                isSendingLocalAttachments: false,
                hasFailedLocalAttachmentUploads: false
            ),
            .sending
        )

        let notSent = MessageSendStatusPresentation.resolve(
            deliveryState: .notSent,
            isSendingLocalAttachments: true,
            hasFailedLocalAttachmentUploads: true
        )
        XCTAssertEqual(notSent, .notSent)
        XCTAssertEqual(notSent.label, "Not sent")

        let deliveryUnknown = MessageSendStatusPresentation.resolve(
            deliveryState: .deliveryUnknown,
            isSendingLocalAttachments: true,
            hasFailedLocalAttachmentUploads: false
        )
        XCTAssertEqual(deliveryUnknown, .deliveryUnknown)
        XCTAssertEqual(deliveryUnknown.label, "Delivery unknown")

        XCTAssertEqual(
            MessageSendStatusPresentation.resolve(
                deliveryState: .none,
                isSendingLocalAttachments: false,
                hasFailedLocalAttachmentUploads: true
            ).label,
            "Send failed"
        )
    }
}
