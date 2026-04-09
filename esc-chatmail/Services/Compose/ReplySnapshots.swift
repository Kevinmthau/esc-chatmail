import Foundation

struct ReplyConversationSnapshot: Sendable {
    let participantEmails: [String]
    let latestThreadId: String?

    init(
        participantEmails: [String],
        latestThreadId: String?
    ) {
        self.participantEmails = participantEmails
        self.latestThreadId = latestThreadId
    }

    @MainActor
    init(conversation: Conversation) {
        self.participantEmails = Array(conversation.participants ?? [])
            .compactMap { $0.person?.email }
        self.latestThreadId = Array(conversation.messages ?? [])
            .sorted { $0.internalDate > $1.internalDate }
            .first?
            .gmThreadId
    }
}

struct ReplyTargetSnapshot: Sendable {
    let subject: String?
    let threadId: String?
    let messageId: String?
    let references: [String]
    let originalMessage: QuotedMessage

    init(
        subject: String?,
        threadId: String?,
        messageId: String?,
        references: [String],
        originalMessage: QuotedMessage
    ) {
        self.subject = subject
        self.threadId = threadId
        self.messageId = messageId
        self.references = references
        self.originalMessage = originalMessage
    }

    @MainActor
    init(message: Message) {
        self.subject = message.subject
        self.threadId = message.gmThreadId
        self.messageId = message.messageIdValue
        self.references = message.referencesValue?
            .split(separator: " ")
            .map(String.init) ?? []
        self.originalMessage = QuotedMessage(
            senderName: message.senderNameValue,
            senderEmail: message.senderEmailValue ?? "",
            date: message.internalDate,
            body: message.bodyTextValue
        )
    }
}
