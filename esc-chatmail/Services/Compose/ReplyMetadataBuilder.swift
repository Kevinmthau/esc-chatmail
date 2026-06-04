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
        replyingTo: ReplyTargetSnapshot?,
        sendAsAliases: [SendAsAlias]
    ) throws -> OutboundMessageRequest.ReplyMetadata {
        let currentUserEmail = authSession.userEmail ?? ""
        let selectedFrom = try ReplyFromAddressSelector(
            sendAsAliases: sendAsAliases,
            fallbackEmail: authSession.userEmail,
            fallbackDisplayName: authSession.userName
        ).select(
            replyFromAddress: replyingTo?.replyFromAddress ?? conversation.replyFromAddress,
            deliveredToAddress: replyingTo?.deliveredToAddress ?? conversation.deliveredToAddress
        )

        let userAddresses = Set(
            ([currentUserEmail] + sendAsAliases.map(\.emailAddress))
                .map(EmailNormalizer.normalize)
                .filter { !$0.isEmpty }
        )

        let recipients = conversation.participantEmails.filter {
            !userAddresses.contains(EmailNormalizer.normalize($0))
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
            fromEmail: selectedFrom.emailAddress,
            fromName: selectedFrom.displayName,
            subject: subject,
            threadId: threadId,
            inReplyTo: inReplyTo,
            references: references,
            originalMessage: originalMessage
        )
    }
}
