import Foundation

struct ReplyConversationSnapshot: Sendable {
    let participantEmails: [String]
    let latestThreadId: String?
    let deliveredToAddress: String?
    let replyFromAddress: String?

    init(
        participantEmails: [String],
        latestThreadId: String?,
        deliveredToAddress: String? = nil,
        replyFromAddress: String? = nil
    ) {
        self.participantEmails = participantEmails
        self.latestThreadId = latestThreadId
        self.deliveredToAddress = deliveredToAddress
        self.replyFromAddress = replyFromAddress
    }

    @MainActor
    init(conversation: Conversation, sendAsAliases: [SendAsAlias] = []) {
        let messages = Array(conversation.messages ?? [])
            .sorted { $0.internalDate > $1.internalDate }
        let latestReplyAddressHint = messages
            .filter { !$0.isFromMe }
            .lazy
            .compactMap { ReplyAddressHint.from(message: $0, sendAsAliases: sendAsAliases) }
            .first

        self.participantEmails = Array(conversation.participants ?? [])
            .compactMap { $0.person?.email }
        self.latestThreadId = messages.first?.gmThreadId
        self.deliveredToAddress = latestReplyAddressHint?.deliveredToAddress
        self.replyFromAddress = latestReplyAddressHint?.replyFromAddress
    }
}

struct ReplyTargetSnapshot: Sendable {
    let subject: String?
    let threadId: String?
    let messageId: String?
    let references: [String]
    let deliveredToAddress: String?
    let replyFromAddress: String?
    let originalMessage: QuotedMessage

    init(
        subject: String?,
        threadId: String?,
        messageId: String?,
        references: [String],
        deliveredToAddress: String?,
        replyFromAddress: String?,
        originalMessage: QuotedMessage
    ) {
        self.subject = subject
        self.threadId = threadId
        self.messageId = messageId
        self.references = references
        self.deliveredToAddress = deliveredToAddress
        self.replyFromAddress = replyFromAddress
        self.originalMessage = originalMessage
    }

    @MainActor
    init(message: Message, sendAsAliases: [SendAsAlias] = [], originalHTML: String? = nil) {
        let replyAddressHint = ReplyAddressHint.from(message: message, sendAsAliases: sendAsAliases)
        self.subject = message.subject
        self.threadId = message.gmThreadId
        self.messageId = message.messageIdValue
        self.references = message.referencesValue?
            .split(separator: " ")
            .map(String.init) ?? []
        self.deliveredToAddress = message.deliveredToAddress.replyAddressValue
            ?? replyAddressHint?.deliveredToAddress
        self.replyFromAddress = message.replyFromAddress.replyAddressValue
            ?? replyAddressHint?.replyFromAddress
        self.originalMessage = QuotedMessage(
            senderName: message.senderNameValue,
            senderEmail: message.senderEmailValue ?? "",
            date: message.internalDate,
            body: message.bodyTextValue,
            originalHTML: originalHTML
        )
    }

    func withOriginalHTML(_ originalHTML: String?) -> ReplyTargetSnapshot {
        ReplyTargetSnapshot(
            subject: subject,
            threadId: threadId,
            messageId: messageId,
            references: references,
            deliveredToAddress: deliveredToAddress,
            replyFromAddress: replyFromAddress,
            originalMessage: QuotedMessage(
                senderName: originalMessage.senderName,
                senderEmail: originalMessage.senderEmail,
                date: originalMessage.date,
                body: originalMessage.body,
                originalHTML: originalHTML
            )
        )
    }
}

private struct ReplyAddressHint {
    let deliveredToAddress: String?
    let replyFromAddress: String?

    @MainActor
    static func from(message: Message, sendAsAliases: [SendAsAlias]) -> ReplyAddressHint? {
        if let storedHint = storedAddressHint(from: message) {
            return storedHint
        }

        return participantAddressHint(from: message, sendAsAliases: sendAsAliases)
    }

    @MainActor
    private static func storedAddressHint(from message: Message) -> ReplyAddressHint? {
        let deliveredToAddress = message.deliveredToAddress.replyAddressValue
        let replyFromAddress = message.replyFromAddress.replyAddressValue
        guard deliveredToAddress != nil || replyFromAddress != nil else {
            return nil
        }

        return ReplyAddressHint(
            deliveredToAddress: deliveredToAddress,
            replyFromAddress: replyFromAddress
        )
    }

    @MainActor
    private static func participantAddressHint(
        from message: Message,
        sendAsAliases: [SendAsAlias]
    ) -> ReplyAddressHint? {
        let aliases = SendAsAlias.deduplicated(sendAsAliases)
        guard !aliases.isEmpty else { return nil }

        let matchingRecipientAliases = Array(message.participants ?? [])
            .filter { recipientKindRank($0.participantKind) != nil }
            .sorted(by: participantSort)
            .compactMap { participant -> SendAsAlias? in
                guard let email = participant.person?.email else { return nil }
                return matchingAlias(for: email, in: aliases)
            }

        guard let alias = matchingRecipientAliases.first(where: { !$0.isDefault }) ??
            matchingRecipientAliases.first else {
            return nil
        }

        return ReplyAddressHint(
            deliveredToAddress: alias.emailAddress,
            replyFromAddress: alias.emailAddress
        )
    }

    private static func matchingAlias(for address: String, in aliases: [SendAsAlias]) -> SendAsAlias? {
        let normalizedAddress = SendAsAlias.normalizedAddress(address)
        return aliases.first { $0.normalizedEmailAddress == normalizedAddress }
    }

    private static func participantSort(_ lhs: MessageParticipant, _ rhs: MessageParticipant) -> Bool {
        let lhsRank = recipientKindRank(lhs.participantKind) ?? Int.max
        let rhsRank = recipientKindRank(rhs.participantKind) ?? Int.max
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }

        let lhsEmail = lhs.person?.email ?? ""
        let rhsEmail = rhs.person?.email ?? ""
        return lhsEmail.localizedCaseInsensitiveCompare(rhsEmail) == .orderedAscending
    }

    private static func recipientKindRank(_ kind: ParticipantKind) -> Int? {
        switch kind {
        case .to:
            return 0
        case .cc:
            return 1
        case .bcc:
            return 2
        case .from:
            return nil
        }
    }
}

private extension Optional where Wrapped == String {
    var replyAddressValue: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
