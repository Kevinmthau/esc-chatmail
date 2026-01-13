import Foundation
import CoreData

@MainActor
final class MessageActions: ObservableObject {
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

    func markAsRead(message: Message) async {
        await updateReadState(message: message, isUnread: false, actionType: .markRead)
    }

    func markAsUnread(message: Message) async {
        await updateReadState(message: message, isUnread: true, actionType: .markUnread)
    }

    func markConversationAsUnread(conversation: Conversation) async {
        let context = coreDataStack.viewContext
        let inboxMessages = fetchInboxMessages(for: conversation, context: context)

        if let latestInboxMessage = inboxMessages.first { // Already sorted by internalDate descending
            await markAsUnread(message: latestInboxMessage)
        } else if let messages = conversation.messages,
                  let latestMessage = messages.max(by: { $0.internalDate < $1.internalDate }) {
            // Fallback to latest message if no INBOX messages
            await markAsUnread(message: latestMessage)
        }
    }

    func markConversationAsRead(conversation: Conversation) async {
        let context = coreDataStack.viewContext
        let unreadInboxMessages = fetchUnreadInboxMessages(for: conversation, context: context)

        for message in unreadInboxMessages {
            await markAsRead(message: message)
        }
    }

    /// Core method for updating message read state - eliminates duplication between markAsRead/markAsUnread
    private func updateReadState(message: Message, isUnread: Bool, actionType: PendingAction.ActionType) async {
        // Skip if already in desired state
        guard message.isUnread != isUnread else { return }

        // Update local state and mark as locally modified for conflict detection
        message.isUnread = isUnread
        message.localModifiedAt = Date()
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
        let context = coreDataStack.newBackgroundContext()

        let gmailMessageId: String? = await context.perform {
            guard let message = try? context.existingObject(with: messageID) as? Message else { return nil }
            guard message.isUnread else { return nil }
            message.isUnread = false
            message.localModifiedAt = Date()
            let messageId = message.id
            try? context.save()
            return messageId
        }

        if let messageId = gmailMessageId, !messageId.isEmpty {
            await pendingActionsManager.queueAction(
                type: .markRead,
                messageId: messageId
            )
        }
    }

    // MARK: - Archive

    func archive(message: Message) async {
        guard let labels = message.labels else { return }
        let inboxLabel = labels.first { $0.id == "INBOX" }
        guard let inboxLabel = inboxLabel else { return }

        // Update local state and mark as locally modified for conflict detection
        message.removeFromLabels(inboxLabel)
        message.localModifiedAt = Date()
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

        // Collect message IDs for syncing and mark as locally modified
        var messageIds: [String] = []
        var removedCount = 0
        let modificationDate = Date()
        for message in messages {
            if let inboxLabel = inboxLabel {
                message.removeFromLabels(inboxLabel)
                message.localModifiedAt = modificationDate
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

    func star(message: Message) async {
        // Note: Star status isn't currently tracked locally in the schema
        // Local-only action (one-way sync: Gmail -> App only)
        coreDataStack.saveIfNeeded(context: coreDataStack.viewContext)
    }

    func unstar(message: Message) async {
        // Local-only action (one-way sync: Gmail -> App only)
        coreDataStack.saveIfNeeded(context: coreDataStack.viewContext)
    }

    // MARK: - Helpers

    /// Fetches INBOX messages for a conversation using Core Data predicates (avoids N+1)
    private func fetchInboxMessages(for conversation: Conversation, context: NSManagedObjectContext) -> [Message] {
        let request = Message.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "conversation == %@", conversation),
            NSPredicate(format: "ANY labels.id == %@", "INBOX")
        ])
        request.sortDescriptors = [NSSortDescriptor(key: "internalDate", ascending: false)]
        return (try? context.fetch(request)) ?? []
    }

    /// Fetches unread INBOX messages for a conversation using Core Data predicates (avoids N+1)
    private func fetchUnreadInboxMessages(for conversation: Conversation, context: NSManagedObjectContext) -> [Message] {
        let request = Message.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "conversation == %@", conversation),
            NSPredicate(format: "ANY labels.id == %@", "INBOX"),
            NSPredicate(format: "isUnread == YES")
        ])
        return (try? context.fetch(request)) ?? []
    }

    private func updateConversationInboxStatus(_ conversation: Conversation) {
        let context = coreDataStack.viewContext
        let inboxMessages = fetchInboxMessages(for: conversation, context: context)

        conversation.hasInbox = !inboxMessages.isEmpty
        conversation.inboxUnreadCount = Int32(inboxMessages.filter { $0.isUnread }.count)
        conversation.latestInboxDate = inboxMessages.first?.internalDate // Already sorted descending

        coreDataStack.saveIfNeeded(context: context)
    }
}
