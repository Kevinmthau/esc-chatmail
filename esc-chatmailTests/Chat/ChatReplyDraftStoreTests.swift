import CoreData
import XCTest
@testable import esc_chatmail

@MainActor
final class ChatReplyDraftStoreTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!
    private var conversation: Conversation!
    private var store: ChatReplyDraftStore!

    override func setUp() async throws {
        stack = TestCoreDataStack()
        context = stack.makeMainQueueViewContext()
        conversation = ConversationBuilder().withDisplayName("Friend").visible().recentlyActive().build(in: context)
        store = ChatReplyDraftStore(context: context)
    }

    override func tearDown() async throws {
        context.reset()
        store = nil
        conversation = nil
        context = nil
        stack = nil
    }

    func testDraftSurvivesContextResetAndProtectsAttachmentsFromOrphanCleanup() throws {
        let id = conversation.id
        let attachment = AttachmentBuilder().withId("local_draft").withFilename("notes.txt").build(in: context)
        try store.save(.init(text: "Unsent text", targetURI: nil, recoveredEnvelope: nil), attachments: [attachment], conversationID: id)
        context.reset()

        let (snapshot, attachments) = try XCTUnwrap(store.load(conversationID: id))
        XCTAssertEqual(snapshot.text, "Unsent text")
        XCTAssertNil(snapshot.targetURI)
        XCTAssertEqual(attachments.map(\.filename), ["notes.txt"])
        let orphanRequest = Attachment.fetchRequest()
        orphanRequest.predicate = AttachmentPredicates.orphaned
        XCTAssertTrue(try context.fetch(orphanRequest).isEmpty)
    }

    func testDraftsAreIsolatedByConversationAndEmptyDraftIsRemoved() throws {
        let otherID = UUID()
        try store.save(.init(text: "First", targetURI: nil, recoveredEnvelope: nil), attachments: [], conversationID: conversation.id)
        try store.save(.init(text: "Second", targetURI: nil, recoveredEnvelope: nil), attachments: [], conversationID: otherID)
        try store.save(.init(text: "", targetURI: nil, recoveredEnvelope: nil), attachments: [], conversationID: conversation.id)
        XCTAssertNil(try store.load(conversationID: conversation.id))
        XCTAssertEqual(try store.load(conversationID: otherID)?.0.text, "Second")
    }

    func testExistingDraftWithoutDataFailsInsteadOfDiscardingAttachments() throws {
        let draft = ChatReplyDraft(context: context)
        draft.conversationId = conversation.id
        let attachment = AttachmentBuilder().withId("local_unreadable_draft").build(in: context)
        attachment.replyDraft = draft
        try context.save()

        XCTAssertThrowsError(try store.load(conversationID: conversation.id))
        XCTAssertFalse(draft.isDeleted)
        XCTAssertEqual(attachment.replyDraft, draft)
    }

    func testOptimisticReplyAtomicallyTakesDraftOwnershipAndSavesEnvelope() async throws {
        let attachment = AttachmentBuilder().withId("local_outgoing").withFilename("notes.txt").build(in: context)
        try store.save(.init(text: "Reply", targetURI: nil, recoveredEnvelope: nil), attachments: [attachment], conversationID: conversation.id)
        let service = GmailSendService(viewContext: context)
        let handle = try await service.createOptimisticMessage(
            to: metadata.recipientEmails, body: "Reply", subject: metadata.subject, threadId: metadata.threadId,
            attachments: [.init(info: .init(localURL: nil, filename: "notes.txt", mimeType: "text/plain"),
                                localAttachmentReference: .init(objectID: attachment.objectID))],
            optimisticConversation: .existingConversation(.init(objectID: conversation.objectID)),
            replyMetadata: metadata
        )
        XCTAssertNil(try store.load(conversationID: conversation.id))
        XCTAssertEqual(attachment.message?.id, handle.optimisticMessageID)
        XCTAssertNil(attachment.replyDraft)
        let record = try mutationRecord(id: handle.optimisticMessageID)
        let saved = try JSONDecoder().decode(StoredReplyEnvelope.self, from: XCTUnwrap(record.replyEnvelopeData))
        XCTAssertEqual(saved.recipients, ["original-recipient@example.com"])
        XCTAssertEqual(saved.inReplyTo, "<original@example.com>")
        XCTAssertEqual(saved.references, ["<earlier@example.com>", "<original@example.com>"])
    }

    func testEditFailedReplyMovesBodyAndAttachmentsIntoDurableDraft() async throws {
        let attachment = AttachmentBuilder().withId("local_failed").withFilename("notes.txt").build(in: context)
        try context.obtainPermanentIDs(for: [conversation, attachment])
        let service = GmailSendService(viewContext: context)
        let handle = try await service.createOptimisticMessage(
            to: metadata.recipientEmails, body: "Keep this reply", subject: metadata.subject, threadId: metadata.threadId,
            attachments: [.init(info: .init(localURL: nil, filename: "notes.txt", mimeType: "text/plain"),
                                localAttachmentReference: .init(objectID: attachment.objectID))],
            optimisticConversation: .existingConversation(.init(objectID: conversation.objectID)),
            replyMetadata: metadata
        )
        service.retainDefinitelyUnsentOptimisticMessage(byID: handle.optimisticMessageID, fallbackAttachmentReferences: [])
        service.recordSendFailureReason(optimisticMessageID: handle.optimisticMessageID, reason: "Rejected by Gmail")
        XCTAssertEqual(try mutationRecord(id: handle.optimisticMessageID).failureReason, "Rejected by Gmail")
        let message = try XCTUnwrap(context.existingObject(with: handle.optimisticMessageObjectID) as? Message)
        let id = conversation.id
        _ = try store.recover(message, conversation: conversation, currentUserEmail: "me@example.com")
        context.reset()

        let (draft, attachments) = try XCTUnwrap(store.load(conversationID: id))
        XCTAssertEqual(draft.text, "Keep this reply")
        XCTAssertEqual(draft.recoveredEnvelope?.recipients, metadata.recipientEmails)
        XCTAssertEqual(draft.recoveredEnvelope?.threadId, metadata.threadId)
        XCTAssertEqual(draft.recoveredEnvelope?.quote?.body, "Original message")
        XCTAssertEqual(attachments.count, 1)
        XCTAssertNil(attachments.first?.message)
        XCTAssertEqual(attachments.first?.state, .queued)
        let request = OutboundSendMutationRecord.fetchRequest()
        XCTAssertTrue(try context.fetch(request).isEmpty)
        XCTAssertEqual(try context.count(for: Message.fetchRequest()), 0)
    }

    func testPreflightRollbackRestoresDurableDraftBeforeComposerResumes() async throws {
        let id = conversation.id
        let attachment = AttachmentBuilder().withId("local_preflight").withFilename("notes.txt").build(in: context)
        try store.save(.init(text: "Keep after preflight", targetURI: nil, recoveredEnvelope: nil),
                       attachments: [attachment], conversationID: id)
        let service = GmailSendService(viewContext: context)
        let handle = try await service.createOptimisticMessage(
            to: metadata.recipientEmails, body: "Keep after preflight", subject: metadata.subject, threadId: metadata.threadId,
            attachments: [.init(info: .init(localURL: nil, filename: "notes.txt", mimeType: "text/plain"),
                                localAttachmentReference: .init(objectID: attachment.objectID))],
            optimisticConversation: .existingConversation(.init(objectID: conversation.objectID)), replyMetadata: metadata
        )
        service.rollbackOptimisticMessageBeforeTransmission(byID: handle.optimisticMessageID, fallbackAttachmentReferences: [])
        context.reset()
        let (draft, attachments) = try XCTUnwrap(store.load(conversationID: id))
        XCTAssertEqual(draft.text, "Keep after preflight")
        XCTAssertEqual(draft.recoveredEnvelope?.inReplyTo, metadata.inReplyTo)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertNil(attachments.first?.message)
        XCTAssertTrue(try context.fetch(OutboundSendMutationRecord.fetchRequest()).isEmpty)
    }

    func testDeliveryUnknownCannotBeMovedToResendDraft() async throws {
        try context.obtainPermanentIDs(for: [conversation])
        let service = GmailSendService(viewContext: context)
        let handle = try await service.createOptimisticMessage(
            to: metadata.recipientEmails, body: "May have been sent",
            optimisticConversation: .existingConversation(.init(objectID: conversation.objectID)), replyMetadata: metadata
        )
        try service.recordAmbiguousRemoteSend(optimisticMessageID: handle.optimisticMessageID)
        let message = try XCTUnwrap(context.existingObject(with: handle.optimisticMessageObjectID) as? Message)
        XCTAssertThrowsError(try store.recover(message, conversation: conversation, currentUserEmail: "me@example.com"))
        XCTAssertFalse(message.isDeleted)
        XCTAssertNil(try store.load(conversationID: conversation.id))
    }

    func testImporterBlocksModelSendAdmission() {
        let composer = ChatComposerState(replyText: "Reply")
        composer.isProcessingAttachments = true
        XCTAssertFalse(composer.beginSending())
        composer.isProcessingAttachments = false
        XCTAssertTrue(composer.beginSending())
    }

    private func mutationRecord(id: String) throws -> OutboundSendMutationRecord {
        let request = OutboundSendMutationRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id)
        return try XCTUnwrap(context.fetch(request).first)
    }

    private var metadata: OutboundMessageRequest.ReplyMetadata {
        .init(recipientEmails: ["original-recipient@example.com"], fromEmail: "me@example.com", fromName: "Me",
              subject: "Re: Original", threadId: "original-thread", inReplyTo: "<original@example.com>",
              references: ["<earlier@example.com>", "<original@example.com>"],
              originalMessage: QuotedMessage(senderName: "Friend", senderEmail: "friend@example.com",
                                             date: Date(timeIntervalSince1970: 1), body: "Original message"))
    }
}
