import Foundation

/// Builds email threading metadata (references, in-reply-to, thread ID) for replies
@MainActor
struct ReplyMetadataBuilder {
    let authSession: AuthSession

    init(authSession: AuthSession) {
        self.authSession = authSession
    }

    func buildReplyMetadata(
        conversation: ReplyConversationSnapshot,
        replyingTo: ReplyTargetSnapshot?
    ) -> OutboundMessageRequest.ReplyMetadata {
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

        return OutboundMessageRequest.ReplyMetadata(
            recipientEmails: recipients,
            subject: subject,
            threadId: threadId,
            inReplyTo: inReplyTo,
            references: references,
            originalMessage: originalMessage
        )
    }
}
