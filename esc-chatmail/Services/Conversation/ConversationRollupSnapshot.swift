import Foundation
import CoreData

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
        // Each write below is skipped when the value is unchanged. Core Data
        // marks a row updated on an equal-value assignment, so an unguarded
        // rollup dirtied every active conversation on every run and each one
        // then fanned through the list's sibling-save handling and the view
        // context merge for nothing.
        // Draft ownership preserves visibility, not stale mailbox state.
        if conversation.hasInbox != hasInbox {
            conversation.hasInbox = hasInbox
        }
        if conversation.inboxUnreadCount != inboxUnreadCount {
            conversation.inboxUnreadCount = inboxUnreadCount
        }
        if conversation.latestInboxDate != latestInboxDate {
            conversation.latestInboxDate = latestInboxDate
        }
        if lastMessageDate == nil {
            // Sync can drain a conversation after the user starts another reply.
            // Preserve its list entry until that saved draft is sent or discarded.
            guard let context = conversation.managedObjectContext else { return }
            let request = NSFetchRequest<ChatReplyDraft>(entityName: "ChatReplyDraft")
            request.predicate = NSPredicate(format: "conversationId == %@", conversation.id as CVarArg)
            request.fetchLimit = 1
            do {
                if try context.count(for: request) > 0 { return }
            } catch {
                Log.error("Failed to check saved draft before empty rollup", category: .coreData, error: error)
                return
            }
        }
        if conversation.lastMessageDate != lastMessageDate {
            conversation.lastMessageDate = lastMessageDate
        }
        let newSnippet: String? = lastMessageDate == nil ? nil : MessagePreviewText.nonEmpty(snippet)
        if conversation.snippet != newSnippet {
            conversation.snippet = newSnippet
        }
        routingPolicy.applyArchiveState(to: conversation, snapshot: self)
    }

    private static func isVisibleMessage(labelIDs: Set<String>) -> Bool {
        labelIDs.isDisjoint(with: MessagePersister.excludedMailboxLabelIDs)
    }
}
