import Foundation
import CoreData

protocol MessageActionsCoreDataStacking: AnyObject {
    var viewContext: NSManagedObjectContext { get }
    func newBackgroundContext() -> NSManagedObjectContext
    @discardableResult
    func saveIfNeeded(context: NSManagedObjectContext, caller: String) -> Bool
}

extension MessageActionsCoreDataStacking {
    @discardableResult
    func saveIfNeeded(context: NSManagedObjectContext) -> Bool {
        saveIfNeeded(context: context, caller: #function)
    }
}

extension CoreDataStack: MessageActionsCoreDataStacking {}

@MainActor
final class MessageActions: ObservableObject {
    private let coreDataStack: any MessageActionsCoreDataStacking
    private let pendingActionsManager: any PendingActionsManagerProtocol

    init(
        coreDataStack: any MessageActionsCoreDataStacking,
        pendingActionsManager: any PendingActionsManagerProtocol
    ) {
        self.coreDataStack = coreDataStack
        self.pendingActionsManager = pendingActionsManager
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
                messageId: messageId,
                payload: nil
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
            context.saveOrLog(operation: "mark message as read")
            return messageId
        }

        if let messageId = gmailMessageId, !messageId.isEmpty {
            await pendingActionsManager.queueAction(
                type: .markRead,
                messageId: messageId,
                payload: nil
            )
        }
    }

    /// Batch mark messages as read - prevents race condition with new messages
    /// Uses a single transaction to ensure atomic update of conversation unread count
    func markMessagesAsReadBatch(messageIDs: [NSManagedObjectID], conversationID: NSManagedObjectID) async {
        guard !messageIDs.isEmpty else { return }

        let context = coreDataStack.newBackgroundContext()

        let gmailMessageIds: [String] = await context.perform {
            var markedIds: [String] = []
            let modificationDate = Date()

            for messageID in messageIDs {
                guard let message = try? context.existingObject(with: messageID) as? Message else { continue }
                guard message.isUnread else { continue }

                message.isUnread = false
                message.localModifiedAt = modificationDate

                if !message.id.isEmpty {
                    markedIds.append(message.id)
                }
            }

            // Update conversation unread count atomically
            if let conv = try? context.existingObject(with: conversationID) as? Conversation {
                conv.inboxUnreadCount = 0
            }

            context.saveOrLog(operation: "batch mark messages as read")
            return markedIds
        }

        // Queue actions for Gmail sync
        for messageId in gmailMessageIds {
            await pendingActionsManager.queueAction(
                type: .markRead,
                messageId: messageId,
                payload: nil
            )
        }
    }

    /// Finds unread inbox messages for the conversation in a background context and marks them
    /// as read in a single transaction. This keeps chat-open work off the main thread.
    func markConversationAsReadIfNeeded(conversationID: UUID, conversationObjectID: NSManagedObjectID) async {
        let context = coreDataStack.newBackgroundContext()

        let gmailMessageIds: [String] = await context.perform {
            let request = NSFetchRequest<Message>(entityName: "Message")
            request.predicate = NSPredicate(
                format: "conversation.id == %@ AND isUnread == YES AND NONE labels.id IN %@",
                conversationID as CVarArg,
                ["DRAFT", "SPAM", "TRASH"]
            )
            request.fetchBatchSize = 50
            request.includesPendingChanges = false

            let unreadMessages = (try? context.fetch(request)) ?? []
            guard !unreadMessages.isEmpty else {
                if let conversation = try? context.existingObject(with: conversationObjectID) as? Conversation,
                   conversation.inboxUnreadCount != 0 {
                    conversation.inboxUnreadCount = 0
                    context.saveOrLog(operation: "clear conversation unread count")
                }
                return []
            }

            let modificationDate = Date()
            let gmailMessageIds = unreadMessages.compactMap { message -> String? in
                guard message.isUnread else { return nil }
                message.isUnread = false
                message.localModifiedAt = modificationDate
                return message.id.isEmpty ? nil : message.id
            }

            if let conversation = try? context.existingObject(with: conversationObjectID) as? Conversation {
                conversation.inboxUnreadCount = 0
            }

            context.saveOrLog(operation: "mark conversation as read if needed")
            return gmailMessageIds
        }

        for messageId in gmailMessageIds {
            await pendingActionsManager.queueAction(
                type: .markRead,
                messageId: messageId,
                payload: nil
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
                messageId: messageId,
                payload: nil
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
        let inboxLabel = fetchLabel(id: "INBOX", in: context, operation: "archive")
        Log.debug("INBOX label found: \(inboxLabel != nil)", category: .message)

        // Collect message IDs for syncing and mark as locally modified
        let modificationDate = Date()
        let mutationResult = applyArchiveLocalChanges(
            to: messages,
            inboxLabel: inboxLabel,
            modificationDate: modificationDate
        )
        let messageIds = mutationResult.messageIds
        let removedCount = mutationResult.affectedMessageCount

        // CRITICAL: Set archivedAt to mark this conversation as archived
        // This ensures that future emails from these participants create a NEW conversation
        let archiveDate = Date()
        conversation.archivedAt = archiveDate
        Log.debug("Set archivedAt to \(archiveDate)", category: .message)

        coreDataStack.saveIfNeeded(context: context)
        Log.debug("Removed INBOX label from \(removedCount) messages, saved context", category: .message)

        updateConversationInboxStatus(conversation)
        Log.debug("Updated conversation inbox status - hasInbox: \(conversation.hasInbox)", category: .message)

        // Queue sync to Gmail
        if !messageIds.isEmpty {
            await pendingActionsManager.queueConversationAction(
                type: .archiveConversation,
                sourceConversationId: conversation.id,
                messageIds: messageIds
            )
        }
    }

    /// Archives multiple conversations in a single batch operation for instant UI response.
    /// - Parameter conversations: The conversations to archive
    /// - Note: Performs a single Core Data save and queues a single pending action.
    func archiveConversations(conversations: [Conversation]) async {
        guard !conversations.isEmpty else { return }

        Log.info("Batch archiving \(conversations.count) conversations", category: .message)

        let context = coreDataStack.viewContext

        // Fetch INBOX label once
        let inboxLabel = fetchLabel(id: "INBOX", in: context, operation: "batch archive")
        guard let inboxLabel = inboxLabel else {
            Log.warning("INBOX label not found, cannot archive", category: .message)
            return
        }

        // Collect all message IDs and update local state in memory
        var allMessageIds: [String] = []
        let modificationDate = Date()

        for conversation in conversations {
            guard let messages = conversation.messages else { continue }

            allMessageIds.append(contentsOf: applyArchiveLocalChanges(
                to: messages,
                inboxLabel: inboxLabel,
                modificationDate: modificationDate
            ).messageIds)

            applyArchivedConversationRollup(to: conversation, at: modificationDate)
        }

        // Single Core Data save for all changes
        coreDataStack.saveIfNeeded(context: context)
        Log.info("Batch archived \(conversations.count) conversations (\(allMessageIds.count) messages)", category: .message)

        // Queue single pending action with all message IDs
        guard let firstConversation = conversations.first else { return }
        if !allMessageIds.isEmpty {
            await pendingActionsManager.queueConversationAction(
                type: .archiveConversation,
                sourceConversationId: firstConversation.id,
                messageIds: allMessageIds
            )
        }
    }

    /// Reports multiple conversations as spam in a single batch operation for instant UI response.
    /// - Parameter conversations: The conversations to report as spam
    /// - Note: Performs a single Core Data save and queues a single pending action.
    func reportSpamConversations(conversations: [Conversation]) async {
        guard !conversations.isEmpty else { return }

        Log.info("Batch reporting \(conversations.count) conversations as spam", category: .message)

        let context = coreDataStack.viewContext

        // Fetch INBOX label for removal and SPAM label for addition
        let inboxLabel = fetchLabel(id: "INBOX", in: context, operation: "batch spam")
        let spamLabel = fetchLabel(id: "SPAM", in: context, operation: "batch spam")

        // Collect all message IDs and update local state in memory
        var allMessageIds: [String] = []
        let modificationDate = Date()

        for conversation in conversations {
            guard let messages = conversation.messages else { continue }

            allMessageIds.append(contentsOf: applySpamLocalChanges(
                to: messages,
                inboxLabel: inboxLabel,
                spamLabel: spamLabel,
                modificationDate: modificationDate
            ))

            applyArchivedConversationRollup(to: conversation, at: modificationDate)
        }

        // Single Core Data save for all changes
        coreDataStack.saveIfNeeded(context: context)
        Log.info("Batch reported \(conversations.count) conversations as spam (\(allMessageIds.count) messages)", category: .message)

        // Queue single pending action with all message IDs
        guard let firstConversation = conversations.first else { return }
        if !allMessageIds.isEmpty {
            await pendingActionsManager.queueConversationAction(
                type: .reportSpam,
                sourceConversationId: firstConversation.id,
                messageIds: allMessageIds
            )
        }
    }

    /// Reports a conversation as spam by adding the SPAM label to all messages.
    /// Also archives the conversation locally to remove it from the chat list.
    /// - Parameter conversation: The conversation to report as spam
    func reportSpamConversation(conversation: Conversation) async {
        Log.debug("reportSpamConversation called for '\(conversation.displayName ?? "unknown")' (id: \(conversation.id))", category: .message)

        guard let messages = conversation.messages, !messages.isEmpty else {
            Log.warning("No messages in conversation '\(conversation.displayName ?? "unknown")' (id: \(conversation.id))", category: .message)
            return
        }

        Log.debug("Found \(messages.count) messages to report as spam", category: .message)

        let context = coreDataStack.viewContext

        // Fetch INBOX label for removal and SPAM label for addition
        let inboxLabel = fetchLabel(id: "INBOX", in: context, operation: "spam")
        let spamLabel = fetchLabel(id: "SPAM", in: context, operation: "spam")

        // Collect message IDs, remove INBOX label locally, add SPAM label, and mark as locally modified
        let modificationDate = Date()
        let messageIds = applySpamLocalChanges(
            to: messages,
            inboxLabel: inboxLabel,
            spamLabel: spamLabel,
            modificationDate: modificationDate
        )

        // Archive the conversation locally and update rollup fields to prevent un-archiving
        applyArchivedConversationRollup(to: conversation, at: modificationDate)

        coreDataStack.saveIfNeeded(context: context)
        Log.debug("Marked \(messageIds.count) messages for spam, removed INBOX labels, archived conversation", category: .message)

        // Queue sync to Gmail
        if !messageIds.isEmpty {
            await pendingActionsManager.queueConversationAction(
                type: .reportSpam,
                sourceConversationId: conversation.id,
                messageIds: messageIds
            )
        }
    }

    // MARK: - Star/Unstar

    func star(message: Message) async {
        await updateStarState(
            message: message,
            isStarred: true,
            actionType: .star
        )
    }

    func unstar(message: Message) async {
        await updateStarState(
            message: message,
            isStarred: false,
            actionType: .unstar
        )
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
        do {
            return try context.fetch(request)
        } catch {
            Log.error("Failed to fetch INBOX messages for conversation", category: .coreData, error: error)
            return []
        }
    }

    /// Fetches unread INBOX messages for a conversation using Core Data predicates (avoids N+1)
    private func fetchUnreadInboxMessages(for conversation: Conversation, context: NSManagedObjectContext) -> [Message] {
        let request = Message.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "conversation == %@", conversation),
            NSPredicate(format: "ANY labels.id == %@", "INBOX"),
            NSPredicate(format: "isUnread == YES")
        ])
        do {
            return try context.fetch(request)
        } catch {
            Log.error("Failed to fetch unread INBOX messages for conversation", category: .coreData, error: error)
            return []
        }
    }

    private func updateConversationInboxStatus(_ conversation: Conversation) {
        let context = coreDataStack.viewContext
        let inboxMessages = fetchInboxMessages(for: conversation, context: context)

        conversation.hasInbox = !inboxMessages.isEmpty
        conversation.inboxUnreadCount = Int32(inboxMessages.filter { $0.isUnread }.count)
        conversation.latestInboxDate = inboxMessages.first?.internalDate // Already sorted descending

        coreDataStack.saveIfNeeded(context: context)
    }

    private func fetchLabel(id: String, in context: NSManagedObjectContext, operation: String) -> Label? {
        let request = Label.fetchRequest()
        request.predicate = LabelPredicates.id(id)
        do {
            return try context.fetch(request).first
        } catch {
            Log.error("Failed to fetch \(id) label for \(operation)", category: .coreData, error: error)
            return nil
        }
    }

    private func applyArchivedConversationRollup(to conversation: Conversation, at date: Date) {
        conversation.archivedAt = date
        conversation.hasInbox = false
        conversation.inboxUnreadCount = 0
        conversation.latestInboxDate = nil
    }

    private func applyArchiveLocalChanges(
        to messages: Set<Message>,
        inboxLabel: Label?,
        modificationDate: Date
    ) -> (messageIds: [String], affectedMessageCount: Int) {
        guard let inboxLabel = inboxLabel else {
            return ([], 0)
        }

        var messageIds: [String] = []
        var affected = 0
        for message in messages {
            message.removeFromLabels(inboxLabel)
            message.localModifiedAt = modificationDate
            affected += 1
            if !message.id.isEmpty {
                messageIds.append(message.id)
            }
        }
        return (messageIds, affected)
    }

    private func applySpamLocalChanges(
        to messages: Set<Message>,
        inboxLabel: Label?,
        spamLabel: Label?,
        modificationDate: Date
    ) -> [String] {
        var messageIds: [String] = []
        for message in messages {
            if let inboxLabel = inboxLabel {
                message.removeFromLabels(inboxLabel)
            }
            if let spamLabel = spamLabel {
                message.addToLabels(spamLabel)
            }
            message.localModifiedAt = modificationDate
            if !message.id.isEmpty {
                messageIds.append(message.id)
            }
        }
        return messageIds
    }

    private func updateStarState(
        message: Message,
        isStarred: Bool,
        actionType: PendingAction.ActionType
    ) async {
        let existingStarLabel = message.labels?.first(where: { $0.id == "STARRED" })
        let alreadyInDesiredState = existingStarLabel != nil

        if isStarred == alreadyInDesiredState {
            return
        }

        if isStarred {
            if let starLabel = existingStarLabel ?? fetchLabel(id: "STARRED", in: coreDataStack.viewContext, operation: "star") {
                message.addToLabels(starLabel)
            } else {
                Log.warning("STARRED label not found locally; queueing remote star only", category: .message)
            }
        } else if let starLabel = existingStarLabel ?? fetchLabel(id: "STARRED", in: coreDataStack.viewContext, operation: "unstar") {
            message.removeFromLabels(starLabel)
        }

        message.localModifiedAt = Date()
        coreDataStack.saveIfNeeded(context: coreDataStack.viewContext, caller: "updateStarState")

        let messageId = message.id
        if !messageId.isEmpty {
            await pendingActionsManager.queueAction(
                type: actionType,
                messageId: messageId,
                payload: nil
            )
        }
    }
}
