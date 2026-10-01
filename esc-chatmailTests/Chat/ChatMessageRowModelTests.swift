import XCTest
import CoreData
@testable import esc_chatmail

/// Every fixture, save, and assertion goes through the suite's `viewContext`, a
/// main-queue context from `TestCoreDataStack.makeMainQueueViewContext()`,
/// never `stack.viewContext`, which is private-queue.
/// `ChatMessageRowModelMapper.map` is `@MainActor` and fetches the
/// optimistic-send records on each message's `managedObjectContext` directly,
/// which is on-queue only for a main-queue context. See that helper for what
/// the private-queue shape races.
///
/// HONEST SCOPE: no test here can reproduce that race on demand. With
/// `-com.apple.CoreData.ConcurrencyDebug 1` the old shape traps and this shape
/// runs clean.
@MainActor
final class ChatMessageRowModelTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var viewContext: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        viewContext = stack.makeMainQueueViewContext()
    }

    override func tearDown() {
        viewContext = nil
        stack = nil
        super.tearDown()
    }

    /// A just-sent row its sync echo has not replaced is flagged, so the
    /// context menu does not offer a Reply that `isValidReplyTarget` refuses.
    ///
    /// Revert-check: mapping `isAwaitingSyncEcho` to a constant false in
    /// `ChatMessageRowModelMapper.map` fails the optimistic row's assertion.
    func testMap_optimisticRowAwaitingEcho_isFlaggedAndDurableRowIsNot() throws {
        let optimisticID = UUID().uuidString
        let optimistic = MessageBuilder().withId(optimisticID).fromMe().build(in: viewContext)
        optimistic.messageId = MimeBuilder.messageId(forOptimisticMessageID: optimisticID)
        let echo = MessageBuilder().withId("gmail-echo-id").fromMe().build(in: viewContext)
        echo.messageId = MimeBuilder.messageId(forOptimisticMessageID: optimisticID)
        try viewContext.save()

        XCTAssertTrue(ChatMessageRowModelMapper.map(optimistic).isAwaitingSyncEcho)
        XCTAssertFalse(ChatMessageRowModelMapper.map(echo).isAwaitingSyncEcho)
    }

    /// Sync replaces an optimistic reply with Gmail's echo: a new `Message` with a new object ID.
    /// Both carry the deterministic RFC Message-ID, so they map to one display identity and the
    /// transcript updates the bubble in place instead of remounting it. Incoming mail never
    /// shares it, even with a Message-ID in the app's own format.
    ///
    /// Revert-check: mapping `displayIdentity` to `.message(message.objectID)` in
    /// `ChatMessageRowModelMapper.map` fails the optimistic/echo equality.
    func testMap_echoReplacingOptimisticRow_keepsDisplayIdentity() throws {
        let optimisticID = UUID().uuidString
        let rfcMessageID = MimeBuilder.messageId(forOptimisticMessageID: optimisticID)
        let optimistic = MessageBuilder().withId(optimisticID).fromMe().build(in: viewContext)
        optimistic.messageId = rfcMessageID
        let echo = MessageBuilder().withId("gmail-echo-id").fromMe().build(in: viewContext)
        echo.messageId = rfcMessageID
        let forgedIncoming = MessageBuilder().withId("incoming-id").build(in: viewContext)
        forgedIncoming.messageId = rfcMessageID
        let unrelated = MessageBuilder().withId("unrelated-id").fromMe().build(in: viewContext)
        unrelated.messageId = "<CAF+external@mail.gmail.com>"
        try viewContext.save()

        let optimisticRow = ChatMessageRowModelMapper.map(optimistic)
        let echoRow = ChatMessageRowModelMapper.map(echo)

        XCTAssertNotEqual(optimisticRow.objectID, echoRow.objectID)
        XCTAssertEqual(
            optimisticRow.displayIdentity,
            .outboundSend(optimisticMessageID: optimisticID)
        )
        XCTAssertEqual(echoRow.displayIdentity, optimisticRow.displayIdentity)
        XCTAssertEqual(echoRow.bubbleContentIdentityKey, optimisticRow.bubbleContentIdentityKey)
        XCTAssertEqual(
            ChatMessageRowModelMapper.map(forgedIncoming).displayIdentity,
            .message(forgedIncoming.objectID)
        )
        XCTAssertEqual(
            ChatMessageRowModelMapper.map(unrelated).displayIdentity,
            .message(unrelated.objectID)
        )
    }

    func testMap_attachmentDimensionsChangeReloadsBubbleContent() async throws {
        let message = MessageBuilder().withId(UUID().uuidString).withAttachments().build(in: viewContext)
        let attachment = viewContext.insertTestObject(Attachment.self)
        attachment.id = UUID().uuidString
        attachment.contentId = "image001"
        attachment.filename = "image001.png"
        attachment.mimeType = "image/png"
        attachment.stateRaw = Attachment.State.downloaded.rawValue
        attachment.message = message
        try viewContext.obtainPermanentIDs(for: [message, attachment])

        let loader = AttachmentRefreshBubbleLoader()
        let viewModel = MessageBubbleViewModel(loader: loader)
        func loadContext() -> MessageBubbleLoadContext {
            let row = ChatMessageRowModelMapper.map(message)
            return MessageBubbleLoadContext(
                messageID: row.id,
                contentSignature: row.loadSignatureComponents.signature(
                    htmlSourceSignature: "unchanged", contactRefreshToken: 0
                ),
                prefetchedSenderName: nil, senderRequest: nil,
                contentRequest: row.makeContentRequest()
            )
        }
        await viewModel.loadIfNeeded(using: loadContext())
        await viewModel.loadIfNeeded(using: loadContext())
        let initialLoads = await loader.loadCount
        XCTAssertEqual(initialLoads, 1)

        attachment.width = 160
        attachment.height = 40
        // Revert-check: omitting attachment metadata from the mapper's load
        // signature leaves the view model's signature unchanged and skips load 2.
        await viewModel.loadIfNeeded(using: loadContext())
        let refreshedLoads = await loader.loadCount
        XCTAssertEqual(refreshedLoads, 2)
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

    /// From the durable send record to the caption under the newest row: "Sent" appears only once
    /// Gmail accepted the reply (record carries Gmail's thread ID) or for a row sync brought from
    /// Gmail, and never for an in-flight, ambiguous, or definitely-unsent record.
    ///
    /// Revert-check: in `MessageSendStatusLinePolicy.line`, returning `.sent` for every own newest
    /// row regardless of presentation fails the in-flight, ambiguous, and not-sent assertions.
    func testMapThenStatusLine_newestOwnRow_showsSentOnlyOnceGmailAccepted() throws {
        let conversation = ConversationBuilder().visible().recentlyActive().build(in: viewContext)
        func optimisticRow(messageID: String?, threadID: String?) -> Message {
            let optimisticID = UUID().uuidString
            let message = MessageBuilder()
                .withId(optimisticID)
                .withBody("Reply \(optimisticID)")
                .fromMe()
                .inConversation(conversation)
                .build(in: viewContext)
            message.messageId = MimeBuilder.messageId(forOptimisticMessageID: optimisticID)
            let record = viewContext.insertTestObject(OutboundSendMutationRecord.self)
            record.id = optimisticID
            record.createdAt = Date()
            record.remoteCommittedMessageId = messageID
            record.remoteCommittedThreadId = threadID
            return message
        }
        let preAdmission = optimisticRow(messageID: nil, threadID: nil)
        let inFlight = optimisticRow(messageID: OutboundSendRemoteState.inFlightMessageID, threadID: nil)
        let ambiguous = optimisticRow(messageID: OutboundSendRemoteState.ambiguousMessageID, threadID: nil)
        let notSent = optimisticRow(messageID: OutboundSendRemoteState.notSentMessageID, threadID: nil)
        let accepted = optimisticRow(messageID: "gmail-message-id", threadID: "gmail-thread-id")
        let synced = MessageBuilder()
            .withId("gmail-synced-sent-row")
            .fromMe()
            .inConversation(conversation)
            .build(in: viewContext)
        synced.messageId = "<synced@example.com>"
        try viewContext.save()

        func newestLine(_ message: Message, isSendingRevealDue: Bool) -> MessageSendStatusLinePolicy.Line? {
            let row = ChatMessageRowModelMapper.map(message)
            return MessageSendStatusLinePolicy.line(
                presentation: MessageSendStatusPresentation.resolve(
                    deliveryState: row.outboundSendDeliveryState,
                    isSendingLocalAttachments: row.isSendingLocalAttachments,
                    hasFailedLocalAttachmentUploads: row.hasFailedLocalAttachmentUploads
                ),
                isSendingRevealDue: isSendingRevealDue,
                isFromMe: row.isFromMe,
                isConfirmedInGmail: row.isConfirmedInGmail,
                isNewestInTranscript: true
            )
        }

        for isSendingRevealDue in [false, true] {
            let pendingLine: MessageSendStatusLinePolicy.Line? = isSendingRevealDue ? .sending : nil
            XCTAssertEqual(newestLine(preAdmission, isSendingRevealDue: isSendingRevealDue), pendingLine)
            XCTAssertEqual(newestLine(inFlight, isSendingRevealDue: isSendingRevealDue), pendingLine)
            XCTAssertEqual(newestLine(ambiguous, isSendingRevealDue: isSendingRevealDue), .deliveryUnknown)
            XCTAssertEqual(newestLine(notSent, isSendingRevealDue: isSendingRevealDue), .notSent)
            XCTAssertEqual(newestLine(accepted, isSendingRevealDue: isSendingRevealDue), .sent)
            XCTAssertEqual(newestLine(synced, isSendingRevealDue: isSendingRevealDue), .sent)
        }
    }

    /// A transient fetch failure while mapping must not turn an optimistic row into a "Sent"
    /// receipt. The mapper logs and falls back to `.none` (it cannot know the record's real
    /// marker, here the ambiguous one), so the row carries no Gmail evidence and the newest-row
    /// caption stays empty, as it did before receipts existed. A synced row in the same batch
    /// keeps its evidence: it does not depend on the record fetch.
    ///
    /// Revert-check: in `ChatMessageRowModelMapper.map(_:fetchOutboundSendMutationRecords:)`,
    /// confirming every row that resolves to `.none` (instead of only rows whose fetched record
    /// resolved to `.none`) fails the optimistic row's assertions.
    func testMapMessages_recordFetchFails_optimisticRowNeverReadsSent() throws {
        struct FetchFailure: Error {}
        let conversation = ConversationBuilder().visible().recentlyActive().build(in: viewContext)
        let optimisticID = UUID().uuidString
        let optimistic = MessageBuilder()
            .withId(optimisticID)
            .withBody("Reply \(optimisticID)")
            .fromMe()
            .inConversation(conversation)
            .build(in: viewContext)
        optimistic.messageId = MimeBuilder.messageId(forOptimisticMessageID: optimisticID)
        let record = viewContext.insertTestObject(OutboundSendMutationRecord.self)
        record.id = optimisticID
        record.createdAt = Date()
        record.remoteCommittedMessageId = OutboundSendRemoteState.ambiguousMessageID
        let synced = MessageBuilder()
            .withId("gmail-synced-row-\(UUID().uuidString)")
            .fromMe()
            .inConversation(conversation)
            .build(in: viewContext)
        synced.messageId = "<synced-\(UUID().uuidString)@example.com>"
        try viewContext.save()

        let rows = ChatMessageRowModelMapper.map(
            [synced, optimistic],
            fetchOutboundSendMutationRecords: { _, _ in throw FetchFailure() }
        )
        let optimisticRow = try XCTUnwrap(rows.last)

        // The fallback the receipt must not trust.
        XCTAssertEqual(optimisticRow.outboundSendDeliveryState, .none)
        XCTAssertFalse(optimisticRow.isConfirmedInGmail)
        XCTAssertNil(MessageSendStatusLinePolicy.line(
            presentation: .none,
            isSendingRevealDue: true,
            isFromMe: optimisticRow.isFromMe,
            isConfirmedInGmail: optimisticRow.isConfirmedInGmail,
            isNewestInTranscript: true
        ))
        XCTAssertTrue(try XCTUnwrap(rows.first).isConfirmedInGmail)
    }

    /// An optimistic row with no record (the lookup found nothing) is equally unproven. The
    /// single-row path resolves through the batch path, so it fails closed the same way.
    ///
    /// Revert-check: treating an optimistic row with no fetched record as confirmed in
    /// `ChatMessageRowModelMapper.map(_:fetchOutboundSendMutationRecords:)` fails the first
    /// assertion; the committed-record assertion pins that real evidence still confirms.
    func testMap_optimisticRowEvidence_requiresRecordWithGmailCommittedIDs() throws {
        let optimisticID = UUID().uuidString
        let optimistic = MessageBuilder().withId(optimisticID).fromMe().build(in: viewContext)
        optimistic.messageId = MimeBuilder.messageId(forOptimisticMessageID: optimisticID)
        try viewContext.save()

        XCTAssertFalse(ChatMessageRowModelMapper.map(optimistic).isConfirmedInGmail)

        let record = viewContext.insertTestObject(OutboundSendMutationRecord.self)
        record.id = optimisticID
        record.createdAt = Date()
        try viewContext.save()
        XCTAssertFalse(ChatMessageRowModelMapper.map(optimistic).isConfirmedInGmail)

        record.remoteCommittedMessageId = "gmail-message-id"
        record.remoteCommittedThreadId = "gmail-thread-id"
        try viewContext.save()
        XCTAssertTrue(ChatMessageRowModelMapper.map(optimistic).isConfirmedInGmail)
    }
}

private actor AttachmentRefreshBubbleLoader: MessageBubbleLoading {
    private(set) var loadCount = 0

    func loadSenderInfo(from request: MessageBubbleSenderRequest) async -> MessageBubbleSenderResult {
        MessageBubbleSenderResult(name: nil, avatarURL: nil, imageData: nil)
    }

    func loadContent(from request: MessageBubbleContentRequest) async -> MessageBubbleContentResult {
        loadCount += 1
        return MessageBubbleContentResult(
            fullTextContent: nil, hasRichHTMLContent: false, sharedDocumentLinks: [],
            forwardedDisplayContent: nil, htmlAnalysis: .empty
        )
    }
}
