import Foundation

/// Derived conversation-list fields computed from the current message set.
struct ConversationRollupSnapshot: Sendable {
    let lastMessageDate: Date?
    let snippet: String?
    let hasInbox: Bool
    let inboxUnreadCount: Int32
    let latestInboxDate: Date?
    let hasSentOrFromMeMessages: Bool
    let hasReceivedMessages: Bool
    let latestVisibleMessageIsOutgoing: Bool

    var isSentOnlyConversation: Bool {
        hasSentOrFromMeMessages && !hasReceivedMessages && !hasInbox
    }

    static func make(from messages: Set<Message>) -> ConversationRollupSnapshot {
        var latestVisibleMessage: Message?
        var latestVisiblePreviewMessage: Message?
        var latestInboxMessage: Message?
        var inboxUnreadCount: Int32 = 0
        var hasSentOrFromMeMessages = false
        var hasReceivedMessages = false

        for message in messages {
            let labelIDs = Set(message.labels?.map(\.id) ?? [])

            if isVisibleMessage(labelIDs: labelIDs) {
                if latestVisibleMessage == nil || message.internalDate > latestVisibleMessage!.internalDate {
                    latestVisibleMessage = message
                }
                if MessagePreviewText.nonEmpty(message.conversationPreviewText) != nil,
                   latestVisiblePreviewMessage == nil || message.internalDate > latestVisiblePreviewMessage!.internalDate {
                    latestVisiblePreviewMessage = message
                }
            }

            if labelIDs.contains("INBOX") {
                if message.isUnread {
                    inboxUnreadCount = min(Int32.max, inboxUnreadCount + 1)
                }
                if latestInboxMessage == nil || message.internalDate > latestInboxMessage!.internalDate {
                    latestInboxMessage = message
                }
            }

            if message.isFromMe || labelIDs.contains("SENT") {
                hasSentOrFromMeMessages = true
            }
            if !message.isFromMe {
                hasReceivedMessages = true
            }
        }

        let latestVisibleLabelIDs = latestVisibleMessage.map { Set($0.labels?.map(\.id) ?? []) } ?? []
        let latestVisibleMessageIsOutgoing = latestVisibleMessage.map {
            $0.isFromMe || latestVisibleLabelIDs.contains("SENT")
        } ?? false

        return ConversationRollupSnapshot(
            lastMessageDate: latestVisibleMessage?.internalDate,
            snippet: latestVisiblePreviewMessage?.conversationPreviewText,
            hasInbox: latestInboxMessage != nil,
            inboxUnreadCount: inboxUnreadCount,
            latestInboxDate: latestInboxMessage?.internalDate,
            hasSentOrFromMeMessages: hasSentOrFromMeMessages,
            hasReceivedMessages: hasReceivedMessages,
            latestVisibleMessageIsOutgoing: latestVisibleMessageIsOutgoing
        )
    }

    func apply(
        to conversation: Conversation,
        routingPolicy: ConversationRoutingPolicy = ConversationRoutingPolicy()
    ) {
        conversation.lastMessageDate = lastMessageDate
        if lastMessageDate == nil {
            conversation.snippet = nil
        } else {
            conversation.snippet = MessagePreviewText.nonEmpty(snippet)
        }
        conversation.hasInbox = hasInbox
        conversation.inboxUnreadCount = inboxUnreadCount
        conversation.latestInboxDate = latestInboxDate
        routingPolicy.applyArchiveState(to: conversation, snapshot: self)
    }

    private static func isVisibleMessage(labelIDs: Set<String>) -> Bool {
        labelIDs.isDisjoint(with: MessagePersister.excludedMailboxLabelIDs)
    }
}
