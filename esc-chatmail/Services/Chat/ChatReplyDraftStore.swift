import CoreData
import Foundation

/// A value snapshot of the original reply envelope. Retrying must not borrow
/// recipients or threading headers from newer messages in the conversation.
struct StoredReplyEnvelope: Codable, Sendable {
    let recipients: [String]
    let fromEmail: String
    let fromName: String?
    let subject: String?
    let threadId: String?
    let inReplyTo: String?
    let references: [String]
    let quote: Quote?

    struct Quote: Codable, Sendable {
        let senderName: String?
        let senderEmail: String
        let date: Date
        let body: String?
        let originalHTML: String?
        let source: ReplyQuotedHTMLSource?
    }

    init(_ metadata: OutboundMessageRequest.ReplyMetadata) {
        recipients = metadata.recipientEmails
        fromEmail = metadata.fromEmail
        fromName = metadata.fromName
        subject = metadata.subject
        threadId = metadata.threadId
        inReplyTo = metadata.inReplyTo
        references = metadata.references
        quote = metadata.originalMessage.map {
            Quote(senderName: $0.senderName, senderEmail: $0.senderEmail,
                  date: $0.date, body: $0.body, originalHTML: $0.originalHTML,
                  source: $0.deferredOriginalHTML?.source)
        }
    }

    func metadata(resolver: ReplyQuotedHTMLResolver) -> OutboundMessageRequest.ReplyMetadata {
        .init(recipientEmails: recipients, fromEmail: fromEmail, fromName: fromName,
              subject: subject, threadId: threadId, inReplyTo: inReplyTo,
              references: references, originalMessage: quote.map {
            QuotedMessage(senderName: $0.senderName, senderEmail: $0.senderEmail,
                          date: $0.date, body: $0.body, originalHTML: $0.originalHTML,
                          deferredOriginalHTML: $0.source.map {
                DeferredReplyQuotedHTML(source: $0, resolver: resolver)
            })
        })
    }
}

struct StoredChatReplyDraft: Codable {
    let text: String
    let targetURI: URL?
    let recoveredEnvelope: StoredReplyEnvelope?
    // Older drafts always displayed the quote for their saved target.
    let includesQuotedMessage: Bool?

    init(text: String, targetURI: URL?, recoveredEnvelope: StoredReplyEnvelope?, includesQuotedMessage: Bool? = nil) {
        self.text = text
        self.targetURI = targetURI
        self.recoveredEnvelope = recoveredEnvelope
        self.includesQuotedMessage = includesQuotedMessage
    }
}

/// Drafts live in the mailbox store, so account removal also removes their
/// text, recipient metadata, and attachment ownership. No per-keystroke changes
/// are published through Conversation or the transcript's observable state.
@MainActor
struct ChatReplyDraftStore {
    let context: NSManagedObjectContext

    func fetch(conversationID: UUID) throws -> ChatReplyDraft? {
        let request = NSFetchRequest<ChatReplyDraft>(entityName: "ChatReplyDraft")
        request.predicate = NSPredicate(format: "conversationId == %@", conversationID as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    func load(conversationID: UUID) throws -> (StoredChatReplyDraft, [Attachment])? {
        guard let record = try fetch(conversationID: conversationID) else { return nil }
        guard let data = record.data else { throw RecoveryError.missingDraftData }
        let snapshot = try JSONDecoder().decode(StoredChatReplyDraft.self, from: data)
        let attachments = Array(record.attachments ?? []).filter { !$0.isDeleted && $0.message == nil }
            .sorted { ($0.id ?? "") < ($1.id ?? "") }
        return (snapshot, attachments)
    }

    func save(_ snapshot: StoredChatReplyDraft, attachments: [Attachment], conversationID: UUID, persist: Bool = true) throws {
        let hasContent = ChatComposerState.hasDraftContent(replyText: snapshot.text, hasAttachments: !attachments.isEmpty)
        if hasContent {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(snapshot)
            let record = try fetch(conversationID: conversationID) ?? ChatReplyDraft(context: context)
            record.conversationId = conversationID
            if record.data != data { record.data = data }
            record.attachments = Set(attachments.filter { !$0.isDeleted && $0.message == nil })
        } else {
            try remove(conversationID: conversationID)
        }
        if persist, context.hasChanges { try context.save() }
    }

    /// Called inside the optimistic-message transaction, after its attachments
    /// have been adopted. A crash leaves either the draft or the durable send.
    func remove(conversationID: UUID) throws {
        guard let record = try fetch(conversationID: conversationID) else { return }
        record.attachments = []
        context.delete(record)
    }

    /// Explicit discard must also work when the snapshot cannot be decoded and
    /// its attachments were never loaded into the composer.
    func discard(conversationID: UUID) throws {
        guard let record = try fetch(conversationID: conversationID) else { return }
        if context.hasChanges { try context.save() }
        let attachments = Array(record.attachments ?? []).filter { !$0.isDeleted }
        let filePaths = attachments.filter { $0.message == nil && $0.isLocalAttachment }
            .flatMap { [$0.localURL, $0.previewURL].compactMap { $0 } }
        do {
            // A send may already own an attachment. Preserve that ownership
            // instead of letting the draft's cascade deletion remove it.
            for attachment in attachments where attachment.message != nil {
                attachment.replyDraft = nil
            }
            context.delete(record)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        for path in filePaths {
            AttachmentPaths.deleteFile(at: path)
        }
    }

    func recover(_ message: Message, conversation: Conversation, currentUserEmail: String) throws -> (StoredChatReplyDraft, [Attachment]) {
        guard message.conversation == conversation,
              OutboundSendDeliveryState.resolve(for: message) == .notSent else {
            throw RecoveryError.notDefinitelyUnsent
        }
        let request = OutboundSendMutationRecord.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", message.id)
        request.fetchLimit = 1
        guard let record = try context.fetch(request).first,
              let data = record.replyEnvelopeData else { throw RecoveryError.missingEnvelope }
        let envelope = try JSONDecoder().decode(StoredReplyEnvelope.self, from: data)
        let snapshot = StoredChatReplyDraft(text: message.bodyTextValue ?? "", targetURI: nil, recoveredEnvelope: envelope)
        let attachments = message.attachmentsArray
        // Establish a clean save boundary so rollback below cannot discard
        // unrelated unsaved edits if moving the failed reply fails.
        if context.hasChanges { try context.save() }
        do {
            let draft = try fetch(conversationID: conversation.id) ?? ChatReplyDraft(context: context)
            draft.conversationId = conversation.id
            draft.data = try JSONEncoder().encode(snapshot)
            for attachment in attachments {
                attachment.message = nil
                attachment.replyDraft = draft
                attachment.state = .queued
            }
            context.delete(message)
            context.delete(record)
            ConversationRollupUpdater().updateRollups(for: conversation, myEmail: currentUserEmail)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return (snapshot, attachments)
    }

    enum RecoveryError: LocalizedError {
        case notDefinitelyUnsent, missingEnvelope, missingDraftData
        var errorDescription: String? {
            switch self {
            case .notDefinitelyUnsent:
                return "Delivery has not been confirmed. Check Gmail before sending this message again."
            case .missingEnvelope:
                return "This older failed message has no saved reply details. Copy its text and select the original message to reply safely."
            case .missingDraftData:
                return "The saved draft could not be read. Reopen this chat to try again, or explicitly discard the draft."
            }
        }
    }
}
