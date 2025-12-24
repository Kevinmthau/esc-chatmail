import Foundation
import CoreData

class MessageActions: ObservableObject {
    private let coreDataStack = CoreDataStack.shared

    // MARK: - Mark Read/Unread

    @MainActor
    func markAsRead(message: Message) async {
        // Update local state only (one-way sync: Gmail -> App only)
        message.isUnread = false
        coreDataStack.saveIfNeeded(context: coreDataStack.viewContext)

        // Update conversation unread count
        if let conversation = message.conversation {
            updateConversationInboxStatus(conversation)
        }
    }

    /// Mark message as read using ObjectID - safe to call from background threads
    func markAsRead(messageID: NSManagedObjectID) async {
        let context = coreDataStack.newBackgroundContext()

        context.performAndWait {
            guard let message = try? context.existingObject(with: messageID) as? Message else { return }
            message.isUnread = false
            try? context.save()
        }
    }

    @MainActor
    func markAsUnread(message: Message) async {
        // Update local state only (one-way sync: Gmail -> App only)
        message.isUnread = true
        coreDataStack.saveIfNeeded(context: coreDataStack.viewContext)

        // Update conversation unread count
        if let conversation = message.conversation {
            updateConversationInboxStatus(conversation)
        }
    }

    // MARK: - Archive

    @MainActor
    func archive(message: Message) async {
        guard let labels = message.labels else { return }
        let inboxLabel = labels.first { $0.id == "INBOX" }
        guard let inboxLabel = inboxLabel else { return }

        // Update local state only (one-way sync: Gmail -> App only)
        message.removeFromLabels(inboxLabel)
        coreDataStack.saveIfNeeded(context: coreDataStack.viewContext)

        if let conversation = message.conversation {
            updateConversationInboxStatus(conversation)
        }
    }

    @MainActor
    func archiveConversation(conversation: Conversation) async {
        print("[ARCHIVE-ACTION] archiveConversation called for '\(conversation.displayName ?? "unknown")' (id: \(conversation.id))")

        guard let messages = conversation.messages, !messages.isEmpty else {
            print("[ARCHIVE-ACTION] ERROR: No messages in conversation '\(conversation.displayName ?? "unknown")' (id: \(conversation.id))")
            return
        }

        print("[ARCHIVE-ACTION] Found \(messages.count) messages to archive")

        // Update local state
        let context = coreDataStack.viewContext
        let labelRequest = Label.fetchRequest()
        labelRequest.predicate = NSPredicate(format: "id == %@", "INBOX")
        let inboxLabel = try? context.fetch(labelRequest).first
        print("[ARCHIVE-ACTION] INBOX label found: \(inboxLabel != nil)")

        // Update local state only (one-way sync: Gmail -> App only)
        var removedCount = 0
        for message in messages {
            if let inboxLabel = inboxLabel {
                message.removeFromLabels(inboxLabel)
                removedCount += 1
            }
        }
        coreDataStack.saveIfNeeded(context: context)
        print("[ARCHIVE-ACTION] Removed INBOX label from \(removedCount) messages, saved context")

        updateConversationInboxStatus(conversation)
        print("[ARCHIVE-ACTION] Updated conversation inbox status - hasInbox: \(conversation.hasInbox)")
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