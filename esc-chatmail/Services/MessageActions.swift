import Foundation
import CoreData

class MessageActions: ObservableObject {
    private let coreDataStack: CoreDataStack
    private let pendingActionsManager: PendingActionsManager

    init(
        coreDataStack: CoreDataStack? = nil,
        pendingActionsManager: PendingActionsManager? = nil
    ) {
        self.coreDataStack = coreDataStack ?? .shared
        self.pendingActionsManager = pendingActionsManager ?? .shared
    }

    // MARK: - Mark Read/Unread

    @MainActor
    func markAsRead(message: Message) async {
        await updateReadState(message: message, isUnread: false, actionType: .markRead)
    }

    @MainActor
    func markAsUnread(message: Message) async {
        await updateReadState(message: message, isUnread: true, actionType: .markUnread)
    }

    @MainActor
    func markConversationAsUnread(conversation: Conversation) async {
        guard let messages = conversation.messages, !messages.isEmpty else { return }

        // Find the latest INBOX message
        let inboxMessages = messages.filter { message in
            guard let labels = message.labels else { return false }
            return labels.contains { $0.id == "INBOX" }
        }

        if let latestInboxMessage = inboxMessages.max(by: { $0.internalDate < $1.internalDate }) {
            await markAsUnread(message: latestInboxMessage)
        } else if let latestMessage = messages.max(by: { $0.internalDate < $1.internalDate }) {
            // Fallback to latest message if no INBOX messages
            await markAsUnread(message: latestMessage)
        }
    }

    @MainActor
    func markConversationAsRead(conversation: Conversation) async {
        guard let messages = conversation.messages, !messages.isEmpty else { return }

        // Mark all unread INBOX messages as read
        let unreadInboxMessages = messages.filter { message in
            guard message.isUnread else { return false }
            guard let labels = message.labels else { return false }
            return labels.contains { $0.id == "INBOX" }
        }

        for message in unreadInboxMessages {
            await markAsRead(message: message)
        }
    }

    /// Core method for updating message read state - eliminates duplication between markAsRead/markAsUnread
    @MainActor
    private func updateReadState(message: Message, isUnread: Bool, actionType: PendingAction.ActionType) async {
        // Skip if already in desired state
        guard message.isUnread != isUnread else { return }

        // Update local state
        message.isUnread = isUnread
        coreDataStack.saveIfNeeded(context: coreDataStack.viewContext)

        // Update conversation unread count
        if let conversation = message.conversation {
            updateConversationInboxStatus(conversation)
        }

        // Queue sync to Gmail
        let messageId = message.id
        if !messageId.isEmpty {
            await pendingActionsManager.queueAction(
                type: actionType,
                messageId: messageId
            )
        }
    }

    /// Mark message as read using ObjectID - safe to call from background threads
    func markAsRead(messageID: NSManagedObjectID) async {
        var gmailMessageId: String?

        let context = coreDataStack.newBackgroundContext()
        context.performAndWait {
            guard let message = try? context.existingObject(with: messageID) as? Message else { return }
            guard message.isUnread else { return }
            message.isUnread = false
            gmailMessageId = message.id
            try? context.save()
        }

        if let messageId = gmailMessageId, !messageId.isEmpty {
            await pendingActionsManager.queueAction(
                type: .markRead,
                messageId: messageId
            )
        }
    }

    // MARK: - Archive

    @MainActor
    func archive(message: Message) async {
        guard let labels = message.labels else { return }
        let inboxLabel = labels.first { $0.id == "INBOX" }
        guard let inboxLabel = inboxLabel else { return }

        // Update local state
        message.removeFromLabels(inboxLabel)
        coreDataStack.saveIfNeeded(context: coreDataStack.viewContext)

        if let conversation = message.conversation {
            updateConversationInboxStatus(conversation)
        }

        // Queue sync to Gmail (remove INBOX label)
        let messageId = message.id
        if !messageId.isEmpty {
            await pendingActionsManager.queueAction(
                type: .archive,
                messageId: messageId
            )
        }
    }

    @MainActor
    func archiveConversation(conversation: Conversation) async {
        Log.debug("archiveConversation called for '\(conversation.displayName ?? "unknown")' (id: \(conversation.id))", category: .message)

        guard let messages = conversation.messages, !messages.isEmpty else {
            Log.warning("No messages in conversation '\(conversation.displayName ?? "unknown")' (id: \(conversation.id))", category: .message)
            return
        }

        Log.debug("Found \(messages.count) messages to archive", category: .message)

        // Update local state
        let context = coreDataStack.viewContext
        let labelRequest = Label.fetchRequest()
        labelRequest.predicate = LabelPredicates.id("INBOX")
        let inboxLabel = try? context.fetch(labelRequest).first
        Log.debug("INBOX label found: \(inboxLabel != nil)", category: .message)

        // Collect message IDs for syncing
        var messageIds: [String] = []
        var removedCount = 0
        for message in messages {
            if let inboxLabel = inboxLabel {
                message.removeFromLabels(inboxLabel)
                removedCount += 1
                if !message.id.isEmpty {
                    messageIds.append(message.id)
                }
            }
        }

        // CRITICAL: Set archivedAt to mark this conversation as archived
        // This ensures that future emails from these participants create a NEW conversation
        conversation.archivedAt = Date()
        Log.debug("Set archivedAt to \(conversation.archivedAt!)", category: .message)

        coreDataStack.saveIfNeeded(context: context)
        Log.debug("Removed INBOX label from \(removedCount) messages, saved context", category: .message)

        updateConversationInboxStatus(conversation)
        Log.debug("Updated conversation inbox status - hasInbox: \(conversation.hasInbox)", category: .message)

        // Queue sync to Gmail
        if !messageIds.isEmpty {
            await pendingActionsManager.queueConversationAction(
                type: .archiveConversation,
                conversationId: conversation.id,
                messageIds: messageIds
            )
        }
    }

    // MARK: - Star/Unstar

    @MainActor
    func star(message: Message) async {
        // Note: Star status isn't currently tracked locally in the schema
        // Local-only action (one-way sync: Gmail -> App only)
        coreDataStack.saveIfNeeded(context: coreDataStack.viewContext)
    }

    @MainActor
    func unstar(message: Message) async {
        // Local-only action (one-way sync: Gmail -> App only)
        coreDataStack.saveIfNeeded(context: coreDataStack.viewContext)
    }

    // MARK: - Helpers

    private func updateConversationInboxStatus(_ conversation: Conversation) {
        guard let messages = conversation.messages else { return }

        let inboxMessages = messages.filter { message in
            guard let labels = message.labels else { return false }
            return labels.contains { $0.id == "INBOX" }
        }

        conversation.hasInbox = !inboxMessages.isEmpty
        conversation.inboxUnreadCount = Int32(inboxMessages.filter { $0.isUnread }.count)

        if let latestInboxMessage = inboxMessages.max(by: { $0.internalDate < $1.internalDate }) {
            conversation.latestInboxDate = latestInboxMessage.internalDate
        } else {
            conversation.latestInboxDate = nil
        }

        coreDataStack.saveIfNeeded(context: coreDataStack.viewContext)
    }
}
