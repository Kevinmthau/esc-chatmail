import Foundation

/// Builds email threading metadata (references, in-reply-to, thread ID) for replies
@MainActor
struct ReplyMetadataBuilder {
    let authSession: AuthSession

    init(authSession: AuthSession) {
        self.authSession = authSession
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
        conversation: Conversation,
        replyingTo: Message?,
        body: String
    ) -> ReplyData {
        let currentUserEmail = authSession.userEmail ?? ""

        // Extract participants from conversation
        let participantEmails = Array(conversation.participants ?? [])
            .compactMap { $0.person?.email }
        let recipients = participantEmails.filter {
            EmailNormalizer.normalize($0) != EmailNormalizer.normalize(currentUserEmail)
        }

        var subject: String?
        var threadId: String?
        var inReplyTo: String?
        var references: [String] = []
        var originalMessage: QuotedMessage?

        if let replyingTo = replyingTo {
            subject = replyingTo.subject.map { MimeBuilder.prefixSubjectForReply($0) }
            threadId = replyingTo.gmThreadId
            inReplyTo = replyingTo.messageIdValue

            // Build references chain
            if let previousRefs = replyingTo.referencesValue, !previousRefs.isEmpty {
                references = previousRefs.split(separator: " ").map(String.init)
            }
            if let messageId = replyingTo.messageIdValue {
                references.append(messageId)
            }

            // Store original message info for quoting
            originalMessage = QuotedMessage(
                senderName: replyingTo.senderNameValue,
                senderEmail: replyingTo.senderEmailValue ?? "",
                date: replyingTo.internalDate,
                body: replyingTo.bodyTextValue
            )
        } else {
            // Find latest message in conversation
            let latestMessage = Array(conversation.messages ?? [])
                .sorted { $0.internalDate > $1.internalDate }
                .first
            threadId = latestMessage?.gmThreadId
        }

        return ReplyData(
            recipients: recipients,
            body: body,
            subject: subject,
            threadId: threadId,
            inReplyTo: inReplyTo,
            references: references,
            originalMessage: originalMessage
        )
    }
}
