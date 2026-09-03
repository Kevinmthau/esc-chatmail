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
        sendAsAliases: [SendAsAlias],
        userAliases: Set<String> = []
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
            ([currentUserEmail] + sendAsAliases.map(\.emailAddress) + Array(userAliases))
                .map(EmailNormalizer.normalize)
                .filter { !$0.isEmpty }
        )

        let usableRecipients: ([String]) -> [String] = { emails in
            emails.filter {
                let normalized = EmailNormalizer.normalize($0)
                return !normalized.isEmpty && !userAddresses.contains(normalized)
            }
        }
        let conversationRecipients = usableRecipients(conversation.participantEmails)
        let replyTargetRecipients = replyingTo.map {
            usableRecipients($0.participantEmails)
        } ?? []
        let normalizedParticipants = Set(
            conversation.participantEmails.map(EmailNormalizer.normalize).filter { !$0.isEmpty }
        )
        let selfFallbackEvidence: ReplyParticipantEvidence?
        if let replyingTo {
            // A targeted reply must be authorized by that exact message. Never
            // borrow evidence from another conversation row when its snapshot
            // is incomplete or synthetic.
            selfFallbackEvidence = replyingTo.participantEvidence
        } else {
            selfFallbackEvidence = conversation.latestThreadParticipantEvidence
        }
        let recipients: [String]
        if conversation.isListConversation, replyingTo != nil {
            recipients = replyTargetRecipients.isEmpty ? conversationRecipients : replyTargetRecipients
        } else if !conversation.isListConversation,
                  conversationRecipients.isEmpty,
                  !normalizedParticipants.isEmpty,
                  normalizedParticipants.isSubset(of: userAddresses),
                  selfFallbackEvidence?.confirmsSelfOnly(in: userAddresses) == true,
                  !EmailNormalizer.normalize(currentUserEmail).isEmpty {
            // Note-to-self conversations keep a self participant for identity.
            // Missing or inconsistent message evidence must fail closed instead.
            recipients = [currentUserEmail]
        } else {
            recipients = conversationRecipients
        }

        var subject: String?
        var threadId: String?
        var inReplyTo: String?
        var references: [String] = []
        var originalMessage: QuotedMessage?

        if let replyingTo = replyingTo {
            guard let targetThreadId = replyingTo.threadId?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !targetThreadId.isEmpty else {
                throw GmailSendService.SendError.replyTargetUnavailable
            }
            subject = replyingTo.subject.map { MimeBuilder.prefixSubjectForReply($0) }
            threadId = targetThreadId
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
