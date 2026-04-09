import Foundation

/// Builds email threading metadata (references, in-reply-to, thread ID) for replies
@MainActor
struct ReplyMetadataBuilder {
    struct ConversationContext {
        let participantEmails: [String]
        let latestThreadId: String?
    }

    struct ReplyTargetContext {
        let subject: String?
        let threadId: String?
        let messageId: String?
        let references: [String]
        let originalMessage: QuotedMessage
    }

    let authSession: AuthSession

    init(authSession: AuthSession) {
        self.authSession = authSession
    }

    struct ReplyMetadata {
        let recipients: [String]
        let subject: String?
        let threadId: String?
        let inReplyTo: String?
        let references: [String]
        let originalMessage: QuotedMessage?
    }

    /// Data needed to send a reply email
    struct ReplyData {
        let recipients: [String]
        let body: String
        let subject: String?
        let threadId: String?
        let inReplyTo: String?
        let references: [String]
        let originalMessage: QuotedMessage?
    }

    func buildReplyData(
        conversation: ConversationContext,
        replyingTo: ReplyTargetContext?,
        body: String
    ) -> ReplyData {
        let metadata = buildReplyMetadata(
            conversation: conversation,
            replyingTo: replyingTo
        )

        return ReplyData(
            recipients: metadata.recipients,
            body: body,
            subject: metadata.subject,
            threadId: metadata.threadId,
            inReplyTo: metadata.inReplyTo,
            references: metadata.references,
            originalMessage: metadata.originalMessage
        )
    }

    func buildReplyMetadata(
        conversation: ConversationContext,
        replyingTo: ReplyTargetContext?
    ) -> ReplyMetadata {
        let currentUserEmail = authSession.userEmail ?? ""

        let recipients = conversation.participantEmails.filter {
            EmailNormalizer.normalize($0) != EmailNormalizer.normalize(currentUserEmail)
        }

        var subject: String?
        var threadId: String?
        var inReplyTo: String?
        var references: [String] = []
        var originalMessage: QuotedMessage?

        if let replyingTo = replyingTo {
            subject = replyingTo.subject.map { MimeBuilder.prefixSubjectForReply($0) }
            threadId = replyingTo.threadId
            inReplyTo = replyingTo.messageId
            references = replyingTo.references
            if let messageId = replyingTo.messageId {
                references.append(messageId)
            }
            originalMessage = replyingTo.originalMessage
        } else {
            threadId = conversation.latestThreadId
        }

        return ReplyMetadata(
            recipients: recipients,
            subject: subject,
            threadId: threadId,
            inReplyTo: inReplyTo,
            references: references,
            originalMessage: originalMessage
        )
    }
}
