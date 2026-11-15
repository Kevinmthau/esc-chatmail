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
        userAliases: Set<String> = [],
        includesQuotedMessage: Bool = true,
        contactLinks: ContactLinkedAddresses = ContactLinkedAddressStore.shared.snapshot()
    ) throws -> OutboundMessageRequest.ReplyMetadata {
        let target = replyingTo ?? conversation.latestReplyTarget
        let currentUserEmail = authSession.userEmail ?? ""
        let selectedFrom = try ReplyFromAddressSelector(
            sendAsAliases: sendAsAliases,
            fallbackEmail: authSession.userEmail,
            fallbackDisplayName: authSession.userName
        ).select(
            replyFromAddress: target?.replyFromAddress ?? conversation.replyFromAddress,
            deliveredToAddress: target?.deliveredToAddress ?? conversation.deliveredToAddress
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
        let replyTargetRecipients = target.map {
            usableRecipients($0.participantEmails)
        } ?? []
        let normalizedParticipants = Set(
            conversation.participantEmails.map(EmailNormalizer.normalize).filter { !$0.isEmpty }
        )
        let selfFallbackEvidence: ReplyParticipantEvidence?
        if let target {
            // A targeted reply must be authorized by that exact message. Never
            // borrow evidence from another conversation row when its snapshot
            // is incomplete or synthetic.
            selfFallbackEvidence = target.participantEvidence
        } else {
            selfFallbackEvidence = conversation.latestThreadParticipantEvidence
        }
        let recipients: [String]
        if conversation.isListConversation, target != nil {
            // A List-Id can contain unrelated threads and recipient sets. Missing
            // target recipients must never borrow another post's addresses.
            recipients = replyTargetRecipients
        } else if target?.usesReplyTo == true, !conversationRecipients.isEmpty {
            // Honor an explicit inbound Reply-To while retaining the non-list
            // conversation identity safety checks for incomplete/stale rows.
            recipients = replyTargetRecipients
        } else if !conversation.isListConversation,
                  conversationRecipients.isEmpty,
                  !normalizedParticipants.isEmpty,
                  normalizedParticipants.isSubset(of: userAddresses),
                  selfFallbackEvidence?.confirmsSelfOnly(in: userAddresses) == true,
                  !EmailNormalizer.normalize(currentUserEmail).isEmpty {
            // Note-to-self conversations keep a self participant for identity.
            // Missing or inconsistent message evidence must fail closed instead.
            recipients = [currentUserEmail]
        } else if let messageRecipients = recipientsOverrulingRows(
            conversation: conversation,
            target: target,
            conversationRecipients: conversationRecipients,
            replyTargetRecipients: replyTargetRecipients,
            usableRecipients: usableRecipients,
            contactLinks: contactLinks,
            userAddresses: userAddresses
        ) {
            // The rows do not describe the message being replied to: a chat
            // merged while a contact card linked two addresses keeps both
            // people's mail after the card stops linking them. Addressed from
            // the rows, the reply (and the message it quotes) would go to
            // someone who was never on that message, or miss the person who
            // wrote it. The message itself says who it was between.
            recipients = messageRecipients
        } else {
            // The rows hold one address for each person. Someone whose
            // contact card links several is answered at the ones the message
            // being replied to used (`ReplyLinkedAddressPolicy`).
            recipients = ReplyLinkedAddressPolicy.recipients(
                conversationRecipients: conversationRecipients,
                targetRecipients: replyTargetRecipients,
                contactLinks: contactLinks,
                userAddresses: userAddresses
            )
        }

        var subject: String?
        var threadId: String?
        var inReplyTo: String?
        var references: [String] = []
        var originalMessage: QuotedMessage?

        if let target {
            guard let targetThreadId = target.threadId?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !targetThreadId.isEmpty else {
                throw GmailSendService.SendError.replyTargetUnavailable
            }
            subject = target.subject.map { MimeBuilder.prefixSubjectForReply($0) }
            threadId = targetThreadId
            inReplyTo = target.messageId
            references = target.references
            if let messageId = target.messageId {
                references.append(messageId)
            }
            originalMessage = includesQuotedMessage ? replyingTo?.originalMessage : nil
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

    /// The people on the message being replied to, when a reply addressed
    /// from the conversation's rows would break a promise to that message
    /// (`ReplyLinkedAddressPolicy.rowsCanAnswer`); nil where the rows answer.
    ///
    /// Asked only of a participant chat that has rows to overrule, and only
    /// where the message's own rows are known to name everyone on it
    /// (`ReplyParticipantEvidence.namesEveryParticipant`). A row set that is
    /// incomplete, or holds only a sender, is no ground for overruling the
    /// conversation: there the rows are the better record. And a conversation
    /// with no usable row keeps failing closed, as the note-to-self case
    /// above requires: this never supplies recipients where there were none.
    private func recipientsOverrulingRows(
        conversation: ReplyConversationSnapshot,
        target: ReplyTargetSnapshot?,
        conversationRecipients: [String],
        replyTargetRecipients: [String],
        usableRecipients: ([String]) -> [String],
        contactLinks: ContactLinkedAddresses,
        userAddresses: Set<String>
    ) -> [String]? {
        guard !conversation.isListConversation,
              !conversationRecipients.isEmpty,
              let target,
              let evidence = target.participantEvidence,
              evidence.namesEveryParticipant else {
            return nil
        }

        // The message's rows in their reply order, then any address only the
        // evidence holds (a sender kept beside a row set with no From row).
        var seen = Set(replyTargetRecipients.map(EmailNormalizer.normalize))
        let messageRecipients = replyTargetRecipients + usableRecipients(evidence.emails).filter {
            seen.insert(EmailNormalizer.normalize($0)).inserted
        }
        guard !messageRecipients.isEmpty,
              !ReplyLinkedAddressPolicy.rowsCanAnswer(
                  conversationRecipients: conversationRecipients,
                  messageParticipants: messageRecipients,
                  messageAuthor: target.originalMessage.senderEmail,
                  contactLinks: contactLinks,
                  userAddresses: userAddresses
              ) else {
            return nil
        }
        return messageRecipients
    }
}
