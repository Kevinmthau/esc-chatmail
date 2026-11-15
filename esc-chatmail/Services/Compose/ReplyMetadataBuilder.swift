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
        let selectedFrom = try ReplyFromAddressSelector(
            sendAsAliases: sendAsAliases,
            fallbackEmail: authSession.userEmail,
            fallbackDisplayName: authSession.userName
        ).select(
            replyFromAddress: target?.replyFromAddress ?? conversation.replyFromAddress,
            deliveredToAddress: target?.deliveredToAddress ?? conversation.deliveredToAddress
        )

        let addressing = replyAddressing(
            conversation: conversation,
            replyingTo: replyingTo,
            sendAsAliases: sendAsAliases,
            userAliases: userAliases,
            contactLinks: contactLinks
        )
        if addressing.overrulesConversationRows {
            // The one trace of a reply that went to other people than the
            // chat it was typed in names. Counts only: addresses stay out of
            // the log.
            Log.info(
                "Reply addressed to the \(addressing.recipients.count) participant(s) of the message being replied to, not the conversation's rows",
                category: .message
            )
        }
        let recipients = addressing.recipients

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

    /// Who a reply goes to: `buildReplyMetadata`'s whole decision about
    /// recipients, and nothing else of the reply.
    ///
    /// It is its own function so the composer can ask before a send what the
    /// send will do (`OutboundReplyContextBuilder.replyAddressing`): the reply
    /// row then names the recipients a chat's title does not. A second copy of
    /// the rule there would say one thing while the send did another.
    func replyAddressing(
        conversation: ReplyConversationSnapshot,
        replyingTo: ReplyTargetSnapshot?,
        sendAsAliases: [SendAsAlias],
        userAliases: Set<String> = [],
        contactLinks: ContactLinkedAddresses = ContactLinkedAddressStore.shared.snapshot()
    ) -> ReplyAddressing {
        let target = replyingTo ?? conversation.latestReplyTarget
        let currentUserEmail = authSession.userEmail ?? ""
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
        var overrulesConversationRows = false
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
            overrulesConversationRows = true
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

        return ReplyAddressing(
            recipients: recipients,
            overrulesConversationRows: overrulesConversationRows
        )
    }

    /// Whether `replyAddressing` is certain to leave the conversation's rows
    /// in charge of a reply to `target`, told from the addresses alone: with
    /// no knowledge of the user's aliases and none of linked contacts.
    ///
    /// The composer asks this first, in the turn its reply target changes
    /// (`OutboundReplyContextBuilder.replyMayOverruleConversationRows`), so
    /// that the ordinary chat never loads aliases to learn that nothing needs
    /// announcing. It may say false where the rows do answer (a linked
    /// participant, a message sent from an alias); the caller then asks
    /// `replyAddressing`. It must never say true where they are overruled,
    /// and it cannot: the rows are overruled only for a fully known message
    /// of a participant chat, when a row's person is not on it or its author
    /// is nobody's row. Knowing the user's addresses only removes addresses
    /// from both sides, and linking only makes more addresses one person, so
    /// a row that is itself an address on the message stays on it, and an
    /// author who is a row, or the account's own address, stays answered.
    func rowsCertainlyAnswer(
        conversationRowEmails: [String],
        isListConversation: Bool,
        target: ReplyTargetSnapshot?
    ) -> Bool {
        guard !isListConversation,
              let target,
              !target.usesReplyTo,
              let evidence = target.participantEvidence,
              evidence.namesEveryParticipant else {
            return true
        }
        func normalized(_ emails: [String]) -> Set<String> {
            Set(emails.map(EmailNormalizer.normalize).filter { !$0.isEmpty })
        }
        let rows = normalized(conversationRowEmails)
        guard !rows.isEmpty else { return true }
        guard rows.isSubset(of: normalized(target.participantEmails + evidence.emails)) else {
            return false
        }
        let author = EmailNormalizer.normalize(target.originalMessage.senderEmail)
        let accountEmail = EmailNormalizer.normalize(authSession.userEmail ?? "")
        return author.isEmpty || rows.contains(author) || (!accountEmail.isEmpty && author == accountEmail)
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
