import Foundation
import CoreData

/// Derived conversation-list fields computed from the current message set.
struct ConversationRollupSnapshot: Sendable, Equatable {
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

    /// The rule over every message of the conversation, walked in memory.
    /// The bounded reader (`ConversationRollupBoundedReader`) gathers the same
    /// inputs from the store for a large conversation and folds in the
    /// context's unsaved messages through the same `Accumulator`, so the rule
    /// has one definition.
    static func make(from messages: Set<Message>) -> ConversationRollupSnapshot {
        var accumulator = Accumulator()
        for message in messages {
            accumulator.add(MessageInput(message))
        }
        return accumulator.snapshot
    }

    /// What the rule reads of one message.
    struct MessageInput: Equatable {
        let id: String
        let internalDate: Date
        let labelIDs: Set<String>
        let isUnread: Bool
        let isFromMe: Bool
        /// `Message.conversationPreviewText`.
        let previewText: String?

        init(_ message: Message) {
            id = message.id
            internalDate = message.internalDate
            labelIDs = Set(message.labels?.map(\.id) ?? [])
            isUnread = message.isUnread
            isFromMe = message.isFromMe
            previewText = message.conversationPreviewText
        }

        var isVisible: Bool {
            labelIDs.isDisjoint(with: MessagePersister.excludedMailboxLabelIDs)
        }

        var isOutgoing: Bool {
            isFromMe || labelIDs.contains("SENT")
        }

        /// Later date first, then the greater ID, so equal dates give one
        /// answer whatever order the messages come in.
        func isNewer(than other: MessageInput?) -> Bool {
            guard let other else { return true }
            if internalDate != other.internalDate {
                return internalDate > other.internalDate
            }
            return id > other.id
        }
    }

    /// The rule, one message at a time. A walk adds every message; the
    /// bounded reader sets the fields from the store's answers and then adds
    /// the unsaved messages.
    struct Accumulator {
        var latestVisible: MessageInput?
        /// The newest visible message whose preview is not blank; it can be
        /// older than `latestVisible`.
        var latestVisiblePreview: MessageInput?
        var latestInbox: MessageInput?
        var inboxUnreadCount: Int32 = 0
        var hasSentOrFromMeMessages = false
        var hasReceivedMessages = false

        mutating func add(_ message: MessageInput) {
            if message.isVisible {
                if message.isNewer(than: latestVisible) {
                    latestVisible = message
                }
                if MessagePreviewText.nonEmpty(message.previewText) != nil,
                   message.isNewer(than: latestVisiblePreview) {
                    latestVisiblePreview = message
                }
            }

            if message.labelIDs.contains("INBOX") {
                if message.isUnread {
                    inboxUnreadCount = min(Int32.max, inboxUnreadCount + 1)
                }
                if message.isNewer(than: latestInbox) {
                    latestInbox = message
                }
            }

            if message.isOutgoing {
                hasSentOrFromMeMessages = true
            }
            if !message.isFromMe {
                hasReceivedMessages = true
            }
        }

        var snapshot: ConversationRollupSnapshot {
            ConversationRollupSnapshot(
                lastMessageDate: latestVisible?.internalDate,
                snippet: latestVisiblePreview?.previewText,
                hasInbox: latestInbox != nil,
                inboxUnreadCount: inboxUnreadCount,
                latestInboxDate: latestInbox?.internalDate,
                hasSentOrFromMeMessages: hasSentOrFromMeMessages,
                hasReceivedMessages: hasReceivedMessages,
                latestVisibleMessageIsOutgoing: latestVisible?.isOutgoing ?? false
            )
        }
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
}
