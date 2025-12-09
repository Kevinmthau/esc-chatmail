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
        guard let messages = conversation.messages, !messages.isEmpty else {
            print("Archive: No messages in conversation")
            return
        }

        // Get ALL message IDs for the API call (Gmail will handle removing INBOX label)
        let allMessageIds = messages.map { $0.id }
        print("Archive: Found \(allMessageIds.count) messages to archive")

        // Update local state
        let context = coreDataStack.viewContext
        let labelRequest = Label.fetchRequest()
        labelRequest.predicate = NSPredicate(format: "id == %@", "INBOX")
        let inboxLabel = try? context.fetch(labelRequest).first

        // Update local state immediately (optimistic update)
        let now = Date()
        for message in messages {
            if let inboxLabel = inboxLabel {
                message.removeFromLabels(inboxLabel)
            }
            message.setValue(now, forKey: "localModifiedAt")
        }
        coreDataStack.saveIfNeeded(context: context)

        updateConversationInboxStatus(conversation)

        // Queue the action for sync with ALL message IDs
        print("Archive: Queueing action for conversation \(conversation.id)")
        await pendingActionsManager.queueConversationAction(
            type: .archiveConversation,
            conversationId: conversation.id,
            messageIds: allMessageIds
        )
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

    // MARK: - Delete

    @MainActor
    func deleteConversation(conversation: Conversation) async {
        guard let messages = conversation.messages else { return }

        let messageIds = messages.map { $0.id }
        guard !messageIds.isEmpty else { return }

        // Update local state immediately (optimistic update)
        conversation.hidden = true
        let now = Date()
        for message in messages {
            message.setValue(now, forKey: "localModifiedAt")
        }
        coreDataStack.saveIfNeeded(context: coreDataStack.viewContext)

        // Queue the action for sync
        await pendingActionsManager.queueConversationAction(
            type: .deleteConversation,
            conversationId: conversation.id,
            messageIds: messageIds
        )
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