import Foundation
import CoreData

class MessageActions: ObservableObject {
    private let coreDataStack = CoreDataStack.shared
    private let pendingActionsManager = PendingActionsManager.shared

    // MARK: - Mark Read/Unread

    @MainActor
    func markAsRead(message: Message) async {
        // Update local state immediately (optimistic update)
        message.isUnread = false
        message.setValue(Date(), forKey: "localModifiedAt")
        coreDataStack.saveIfNeeded(context: coreDataStack.viewContext)

        // Update conversation unread count
        if let conversation = message.conversation {
            updateConversationInboxStatus(conversation)
        }

        // Queue the action for sync
        await pendingActionsManager.queueAction(type: .markRead, messageId: message.id)
    }

    /// Mark message as read using ObjectID - safe to call from background threads
    func markAsRead(messageID: NSManagedObjectID) async {
        let context = coreDataStack.newBackgroundContext()
        var messageIdString: String?

        context.performAndWait {
            guard let message = try? context.existingObject(with: messageID) as? Message else { return }
            message.isUnread = false
            message.setValue(Date(), forKey: "localModifiedAt")
            messageIdString = message.id
            try? context.save()
        }

        // Queue the action for sync
        if let id = messageIdString {
            await pendingActionsManager.queueAction(type: .markRead, messageId: id)
        }
    }

    @MainActor
    func markAsUnread(message: Message) async {
        // Update local state immediately (optimistic update)
        message.isUnread = true
        message.setValue(Date(), forKey: "localModifiedAt")
        coreDataStack.saveIfNeeded(context: coreDataStack.viewContext)

        // Update conversation unread count
        if let conversation = message.conversation {
            updateConversationInboxStatus(conversation)
        }

        // Queue the action for sync
        await pendingActionsManager.queueAction(type: .markUnread, messageId: message.id)
    }

    // MARK: - Archive

    @MainActor
    func archive(message: Message) async {
        guard let labels = message.labels else { return }
        let inboxLabel = labels.first { $0.id == "INBOX" }
        guard let inboxLabel = inboxLabel else { return }

        // Update local state immediately (optimistic update)
        message.removeFromLabels(inboxLabel)
        message.setValue(Date(), forKey: "localModifiedAt")
        coreDataStack.saveIfNeeded(context: coreDataStack.viewContext)

        if let conversation = message.conversation {
            updateConversationInboxStatus(conversation)
        }

        // Queue the action for sync
        await pendingActionsManager.queueAction(type: .archive, messageId: message.id)
    }

    @MainActor
    func archiveConversation(conversation: Conversation) async {
        print("[ARCHIVE-ACTION] archiveConversation called for '\(conversation.displayName ?? "unknown")' (id: \(conversation.id))")

        guard let messages = conversation.messages, !messages.isEmpty else {
            print("[ARCHIVE-ACTION] ERROR: No messages in conversation '\(conversation.displayName ?? "unknown")' (id: \(conversation.id))")
            return
        }

        // Get ALL message IDs for the API call (Gmail will handle removing INBOX label)
        let allMessageIds = messages.map { $0.id }
        print("[ARCHIVE-ACTION] Found \(allMessageIds.count) messages to archive:")
        for (index, msg) in messages.enumerated() {
            let hasInbox = msg.labels?.contains { $0.id == "INBOX" } ?? false
            print("[ARCHIVE-ACTION]   [\(index + 1)] msgId: \(msg.id), hasINBOX: \(hasInbox), subject: '\(msg.subject ?? "no subject")'")
        }

        // Update local state
        let context = coreDataStack.viewContext
        let labelRequest = Label.fetchRequest()
        labelRequest.predicate = NSPredicate(format: "id == %@", "INBOX")
        let inboxLabel = try? context.fetch(labelRequest).first
        print("[ARCHIVE-ACTION] INBOX label found: \(inboxLabel != nil)")

        // Update local state immediately (optimistic update)
        let now = Date()
        var removedCount = 0
        for message in messages {
            if let inboxLabel = inboxLabel {
                message.removeFromLabels(inboxLabel)
                removedCount += 1
            }
            message.setValue(now, forKey: "localModifiedAt")
        }
        coreDataStack.saveIfNeeded(context: context)
        print("[ARCHIVE-ACTION] Removed INBOX label from \(removedCount) messages, saved context")

        updateConversationInboxStatus(conversation)
        print("[ARCHIVE-ACTION] Updated conversation inbox status - hasInbox: \(conversation.hasInbox)")

        // Queue the action for sync with ALL message IDs
        print("[ARCHIVE-ACTION] Queueing pending action for conversation \(conversation.id) with \(allMessageIds.count) message IDs")
        await pendingActionsManager.queueConversationAction(
            type: .archiveConversation,
            conversationId: conversation.id,
            messageIds: allMessageIds
        )
        print("[ARCHIVE-ACTION] Pending action queued successfully")
    }

    // MARK: - Star/Unstar

    @MainActor
    func star(message: Message) async {
        // Note: Star status isn't currently tracked locally in the schema
        // but we still queue the action for sync
        message.setValue(Date(), forKey: "localModifiedAt")
        coreDataStack.saveIfNeeded(context: coreDataStack.viewContext)

        await pendingActionsManager.queueAction(type: .star, messageId: message.id)
    }

    @MainActor
    func unstar(message: Message) async {
        message.setValue(Date(), forKey: "localModifiedAt")
        coreDataStack.saveIfNeeded(context: coreDataStack.viewContext)

        await pendingActionsManager.queueAction(type: .unstar, messageId: message.id)
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