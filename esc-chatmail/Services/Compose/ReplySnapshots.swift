import Foundation
import CoreData

struct ReplyParticipantEvidence: Sendable {
    let emails: [String]
    let hasAddressableRecipientRow: Bool
    let isComplete: Bool

    func confirmsSelfOnly(in userAddresses: Set<String>) -> Bool {
        let normalizedEmails = Set(
            emails.map(EmailNormalizer.normalize).filter { !$0.isEmpty }
        )
        return hasAddressableRecipientRow &&
            isComplete &&
            !normalizedEmails.isEmpty &&
            normalizedEmails.isSubset(of: userAddresses)
    }
}

struct ReplyConversationSnapshot: Sendable {
    let participantEmails: [String]
    let isListConversation: Bool
    let latestThreadId: String?
    let deliveredToAddress: String?
    let replyFromAddress: String?
    let latestThreadParticipantEvidence: ReplyParticipantEvidence?

    init(
        participantEmails: [String],
        isListConversation: Bool = false,
        latestThreadId: String?,
        deliveredToAddress: String? = nil,
        replyFromAddress: String? = nil,
        latestThreadParticipantEvidence: ReplyParticipantEvidence? = nil
    ) {
        self.participantEmails = participantEmails
        self.isListConversation = isListConversation
        self.latestThreadId = latestThreadId
        self.deliveredToAddress = deliveredToAddress
        self.replyFromAddress = replyFromAddress
        self.latestThreadParticipantEvidence = latestThreadParticipantEvidence
    }

    @MainActor
    init(
        conversation: Conversation,
        replyingTo: ReplyTargetSnapshot? = nil,
        sendAsAliases: [SendAsAlias] = []
    ) {
        let isListConversation = conversation.conversationType == .list
        let latestListInboundMessage = isListConversation
            ? Self.latestInboundListMessage(in: conversation)
            : nil
        let latestNonListReplyAddressHint = !isListConversation && replyingTo != nil
            ? Self.latestInboundReplyAddressHint(
                in: conversation,
                sendAsAliases: sendAsAliases
            )
            : nil
        let nonListMessages = isListConversation || replyingTo != nil
            ? []
            : Array(conversation.messages ?? []).sorted(by: Self.messageSort)
        let latestNonListReplyAnchor = Self.latestNonListReplyAnchor(in: nonListMessages)
        let latestReplyAddressHint: ReplyAddressHint?
        if isListConversation {
            latestReplyAddressHint = latestListInboundMessage.flatMap {
                ReplyAddressHint.from(message: $0, sendAsAliases: sendAsAliases)
            }
        } else if replyingTo != nil {
            latestReplyAddressHint = latestNonListReplyAddressHint
        } else {
            latestReplyAddressHint = nonListMessages
                .filter { !$0.isFromMe }
                .lazy
                .compactMap { ReplyAddressHint.from(message: $0, sendAsAliases: sendAsAliases) }
                .first
        }

        if isListConversation {
            self.participantEmails = latestListInboundMessage.map {
                ReplyParticipantSnapshot.recipientEmails(
                    from: $0,
                    replacingFromWithReplyTo: true
                )
            } ?? []
        } else {
            self.participantEmails = Array(conversation.participants ?? [])
                .compactMap { participant in
                    guard let person = participant.person,
                          !EmailNormalizer.isHideMyEmailDisplayName(person.displayName) else {
                        return nil
                    }
                    return person.email
                }
        }
        self.isListConversation = isListConversation
        self.latestThreadId = replyingTo?.threadId ?? (isListConversation
            ? latestListInboundMessage?.gmThreadId
            : latestNonListReplyAnchor?.threadId)
        self.deliveredToAddress = latestReplyAddressHint?.deliveredToAddress
        self.replyFromAddress = latestReplyAddressHint?.replyFromAddress
        self.latestThreadParticipantEvidence = latestNonListReplyAnchor?.participantEvidence
    }

    private struct NonListReplyAnchor {
        let threadId: String?
        let participantEvidence: ReplyParticipantEvidence
    }

    @MainActor
    private static func latestNonListReplyAnchor(in messages: [Message]) -> NonListReplyAnchor? {
        for message in messages {
            let threadId = message.gmThreadId.trimmingCharacters(in: .whitespacesAndNewlines)
            if threadId.isEmpty {
                // Keep a new compose/forward boundary until its row receives the
                // committed thread, even if its delivery state already reads sent.
                if OutboundSendDeliveryState.localOptimisticMessageID(for: message) != nil {
                    return NonListReplyAnchor(
                        threadId: nil,
                        participantEvidence: ReplyParticipantSnapshot.evidence(from: message)
                    )
                }
                continue
            }
            if OutboundSendDeliveryState.resolve(for: message) == .none {
                return NonListReplyAnchor(
                    threadId: threadId,
                    participantEvidence: ReplyParticipantSnapshot.evidence(from: message)
                )
            }
        }
        return nil
    }

    @MainActor
    private static func latestInboundReplyAddressHint(
        in conversation: Conversation,
        sendAsAliases: [SendAsAlias]
    ) -> ReplyAddressHint? {
        guard let context = conversation.managedObjectContext else {
            return Array(conversation.messages ?? [])
                .sorted(by: messageSort)
                .filter { !$0.isFromMe }
                .lazy
                .compactMap { ReplyAddressHint.from(message: $0, sendAsAliases: sendAsAliases) }
                .first
        }

        let request = Message.fetchRequest()
        let conversationPredicate = NSPredicate(
            format: "conversation == %@ AND isFromMe == NO",
            conversation
        )
        request.predicate = conversationPredicate
        request.sortDescriptors = [
            NSSortDescriptor(key: "internalDate", ascending: false),
            NSSortDescriptor(key: "id", ascending: false)
        ]
        let pageSize = 32
        request.fetchLimit = pageSize
        request.fetchBatchSize = pageSize
        request.includesPendingChanges = true
        request.relationshipKeyPathsForPrefetching = [
            "participants",
            "participants.person"
        ]

        var cursor: (date: Date, id: String)?
        while true {
            if let cursor {
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    conversationPredicate,
                    NSCompoundPredicate(orPredicateWithSubpredicates: [
                        NSPredicate(
                            format: "internalDate < %@",
                            cursor.date as NSDate
                        ),
                        NSCompoundPredicate(andPredicateWithSubpredicates: [
                            NSPredicate(
                                format: "internalDate == %@",
                                cursor.date as NSDate
                            ),
                            NSPredicate(format: "id < %@", cursor.id)
                        ])
                    ])
                ])
            }
            guard let messages = try? context.fetch(request), !messages.isEmpty else {
                return nil
            }
            if let hint = messages.lazy.compactMap({
                ReplyAddressHint.from(message: $0, sendAsAliases: sendAsAliases)
            }).first {
                return hint
            }
            guard messages.count == pageSize, let lastMessage = messages.last else {
                return nil
            }
            cursor = (lastMessage.internalDate, lastMessage.id)
        }
    }

    private static func latestInboundListMessage(
        in conversation: Conversation
    ) -> Message? {
        guard let listId = conversation.listId, !listId.isEmpty else {
            return nil
        }

        guard let context = conversation.managedObjectContext else {
            return Array(conversation.messages ?? [])
                .sorted(by: messageSort)
                .first { !$0.isFromMe && $0.listId == listId }
        }

        let request = Message.fetchRequest()
        request.predicate = NSPredicate(
            format: "conversation == %@ AND isFromMe == NO AND listId == %@",
            conversation,
            listId
        )
        request.sortDescriptors = [
            NSSortDescriptor(key: "internalDate", ascending: false),
            NSSortDescriptor(key: "id", ascending: false)
        ]
        request.fetchLimit = 1
        request.fetchBatchSize = 1
        request.includesPendingChanges = true
        request.relationshipKeyPathsForPrefetching = [
            "participants",
            "participants.person"
        ]

        return try? context.fetch(request).first
    }

    private static func messageSort(_ lhs: Message, _ rhs: Message) -> Bool {
        if lhs.internalDate != rhs.internalDate {
            return lhs.internalDate > rhs.internalDate
        }
        return lhs.id > rhs.id
    }
}

struct ReplyTargetSnapshot: Sendable {
    let participantEmails: [String]
    let subject: String?
    let threadId: String?
    let messageId: String?
    let references: [String]
    let deliveredToAddress: String?
    let replyFromAddress: String?
    let originalMessage: QuotedMessage
    let participantEvidence: ReplyParticipantEvidence?

    init(
        participantEmails: [String],
        subject: String?,
        threadId: String?,
        messageId: String?,
        references: [String],
        deliveredToAddress: String?,
        replyFromAddress: String?,
        originalMessage: QuotedMessage,
        participantEvidence: ReplyParticipantEvidence? = nil
    ) {
        self.participantEmails = participantEmails
        self.subject = subject
        self.threadId = threadId
        self.messageId = messageId
        self.references = references
        self.deliveredToAddress = deliveredToAddress
        self.replyFromAddress = replyFromAddress
        self.originalMessage = originalMessage
        self.participantEvidence = participantEvidence
    }

    @MainActor
    init(
        message: Message,
        sendAsAliases: [SendAsAlias] = [],
        originalHTML: String? = nil,
        deferredOriginalHTML: DeferredReplyQuotedHTML? = nil
    ) {
        let replyAddressHint = ReplyAddressHint.from(message: message, sendAsAliases: sendAsAliases)
        self.participantEmails = ReplyParticipantSnapshot.recipientEmails(
            from: message,
            replacingFromWithReplyTo: message.conversation?.conversationType == .list
        )
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
        self.participantEvidence = ReplyParticipantSnapshot.evidence(from: message)
        self.originalMessage = QuotedMessage(
            senderName: message.senderNameValue,
            senderEmail: message.senderEmailValue ?? "",
            date: message.internalDate,
            body: message.bodyTextValue,
            originalHTML: originalHTML,
            deferredOriginalHTML: deferredOriginalHTML
        )
    }

    func withOriginalHTML(_ originalHTML: String?) -> ReplyTargetSnapshot {
        ReplyTargetSnapshot(
            participantEmails: participantEmails,
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
            ),
            participantEvidence: participantEvidence
        )
    }
}

private enum ReplyParticipantSnapshot {
    @MainActor
    static func evidence(from message: Message) -> ReplyParticipantEvidence {
        let participants = Array(message.participants ?? []).filter {
            $0.participantKind != .bcc
        }
        var seen = Set<String>()
        var emails: [String] = []
        var hasAddressableRecipientRow = false
        var hasSenderEvidence = false
        var isComplete = !participants.isEmpty

        for participant in participants {
            guard let person = participant.person,
                  !EmailNormalizer.isHideMyEmailDisplayName(person.displayName) else {
                isComplete = false
                continue
            }
            let normalized = EmailNormalizer.normalize(person.email)
            guard !normalized.isEmpty else {
                isComplete = false
                continue
            }
            if participant.participantKind == .from {
                hasSenderEvidence = true
            } else {
                hasAddressableRecipientRow = true
            }
            if seen.insert(normalized).inserted {
                emails.append(person.email)
            }
        }

        if let senderEmail = message.senderEmailValue {
            let normalized = EmailNormalizer.normalize(senderEmail)
            if normalized.isEmpty || EmailNormalizer.isHideMyEmailDisplayName(message.senderNameValue) {
                isComplete = false
            } else {
                hasSenderEvidence = true
                if seen.insert(normalized).inserted {
                    emails.append(senderEmail)
                }
            }
        }

        return ReplyParticipantEvidence(
            emails: emails,
            hasAddressableRecipientRow: hasAddressableRecipientRow,
            isComplete: isComplete && hasSenderEvidence
        )
    }

    @MainActor
    static func recipientEmails(
        from message: Message,
        replacingFromWithReplyTo: Bool = false
    ) -> [String] {
        let replyToEmails = replacingFromWithReplyTo
            ? message.replyTo.map { header in
                EmailAddressListParser.addressTokens(from: header)
                    .filter { token in
                        !EmailNormalizer.isHideMyEmailDisplayName(
                            EmailNormalizer.extractDisplayName(from: token)
                        )
                    }
                    .flatMap { EmailAddressListParser.emailAddresses(from: $0) }
            } ?? []
            : []
        let participants = Array(message.participants ?? [])
            .filter {
                $0.participantKind != .bcc &&
                    (replyToEmails.isEmpty || $0.participantKind != .from)
            }
            .sorted(by: participantSort)

        var seen = Set<String>()
        var recipientEmails: [String] = []

        for email in replyToEmails {
            let normalized = EmailNormalizer.normalize(email)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                continue
            }
            recipientEmails.append(email)
        }

        recipientEmails.append(contentsOf: participants.compactMap { participant in
            guard let person = participant.person,
                  !EmailNormalizer.isHideMyEmailDisplayName(person.displayName) else {
                return nil
            }
            let email = person.email
            let normalized = EmailNormalizer.normalize(email)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                return nil
            }
            return email
        })
        return recipientEmails
    }

    private static func participantSort(_ lhs: MessageParticipant, _ rhs: MessageParticipant) -> Bool {
        let lhsRank = participantKindRank(lhs.participantKind)
        let rhsRank = participantKindRank(rhs.participantKind)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }

        let lhsEmail = lhs.person?.email ?? ""
        let rhsEmail = rhs.person?.email ?? ""
        return lhsEmail.localizedCaseInsensitiveCompare(rhsEmail) == .orderedAscending
    }

    private static func participantKindRank(_ kind: ParticipantKind) -> Int {
        switch kind {
        case .from:
            return 0
        case .to:
            return 1
        case .cc:
            return 2
        case .bcc:
            return 3
        }
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
