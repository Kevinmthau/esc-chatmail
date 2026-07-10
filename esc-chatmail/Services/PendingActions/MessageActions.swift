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
    typealias UnreadInboxMessageCounter = @Sendable (NSManagedObjectContext, Conversation) throws -> Int

    private let coreDataStack: any MessageActionsCoreDataStacking
    private let pendingActionsManager: any PendingActionsManagerProtocol
    private let unreadInboxMessageCounter: UnreadInboxMessageCounter
    private let rollupMutationSerializer: ConversationRollupMutationSerializer

    init(
        coreDataStack: any MessageActionsCoreDataStacking,
        pendingActionsManager: any PendingActionsManagerProtocol,
        rollupMutationSerializer: ConversationRollupMutationSerializer = .shared
    ) {
        self.coreDataStack = coreDataStack
        self.pendingActionsManager = pendingActionsManager
        self.rollupMutationSerializer = rollupMutationSerializer
        self.unreadInboxMessageCounter = { context, conversation in
            try Self.countUnreadInboxMessages(in: context, conversation: conversation)
        }
    }

    init(
        coreDataStack: any MessageActionsCoreDataStacking,
        pendingActionsManager: any PendingActionsManagerProtocol,
        unreadInboxMessageCounter: @escaping UnreadInboxMessageCounter,
        rollupMutationSerializer: ConversationRollupMutationSerializer = .shared
    ) {
        self.coreDataStack = coreDataStack
        self.pendingActionsManager = pendingActionsManager
        self.unreadInboxMessageCounter = unreadInboxMessageCounter
        self.rollupMutationSerializer = rollupMutationSerializer
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
        }
    }

    func markConversationAsRead(conversation: Conversation) async {
        let context = coreDataStack.viewContext
        let unreadInboxMessageIDs = snapshotUnreadInboxMessageObjectIDs(for: conversation, context: context)
        guard !unreadInboxMessageIDs.isEmpty else { return }

        await markMessagesAsReadBatch(
            messageIDs: unreadInboxMessageIDs,
            conversationID: conversation.objectID
        )
    }

    /// Snapshots the unread message IDs that should be cleared when a chat opens.
    /// Capturing these IDs on the main context avoids racing newer arrivals.
    func snapshotUnreadInboxMessageObjectIDs(conversationID: UUID) -> [NSManagedObjectID] {
        let request = NSFetchRequest<NSManagedObjectID>(entityName: "Message")
        request.predicate = NSPredicate(
            format: "conversation.id == %@ AND isUnread == YES AND ANY labels.id == %@",
            conversationID as CVarArg,
            "INBOX"
        )
        request.fetchBatchSize = 50
        request.includesPendingChanges = false
        request.resultType = .managedObjectIDResultType

        return (try? coreDataStack.viewContext.fetch(request)) ?? []
    }

    /// Filters an exact insertion set down to unread INBOX messages.
    /// This prevents a later arrival from consuming unrelated unread mail.
    func snapshotUnreadInboxMessageObjectIDs(
        messageObjectIDs: [NSManagedObjectID]
    ) -> [NSManagedObjectID] {
        guard !messageObjectIDs.isEmpty else { return [] }

        let request = NSFetchRequest<NSManagedObjectID>(entityName: "Message")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "SELF IN %@", messageObjectIDs),
            NSPredicate(format: "isUnread == YES"),
            NSPredicate(format: "ANY labels.id == %@", "INBOX")
        ])
        request.fetchBatchSize = messageObjectIDs.count
        request.includesPendingChanges = false
        request.resultType = .managedObjectIDResultType

        return (try? coreDataStack.viewContext.fetch(request)) ?? []
    }

    /// Core method for updating message read state - eliminates duplication between markAsRead/markAsUnread
    private func updateReadState(message: Message, isUnread: Bool, actionType: PendingAction.ActionType) async {
        // Skip if already in desired state
        guard message.isUnread != isUnread else { return }

        // Update local state and mark as locally modified for conflict detection
        message.isUnread = isUnread
        message.localModifiedAt = Date()
        let saved = coreDataStack.saveIfNeeded(context: coreDataStack.viewContext)

        // Update conversation unread count
        if let conversation = message.conversation {
            updateConversationInboxStatus(conversation)
        }

        // Only sync to Gmail if the optimistic change actually persisted locally.
        // Pushing a remote mutation we failed to store would diverge Gmail from local state.
        guard saved else {
            Log.error("Not queuing \(actionType.rawValue) for message \(message.id): local save failed", category: .message)
            return
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
            // Only return the id (and thus queue a remote markRead) if the local change persisted.
            guard context.saveOrLog(operation: "mark message as read") else { return nil }
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
        let conversationKey = conversationID.uriRepresentation().absoluteString
        await rollupMutationSerializer.perform(conversationKeys: [conversationKey]) { [weak self] in
            await self?.performMarkMessagesAsReadBatch(
                messageIDs: messageIDs,
                conversationID: conversationID
            )
        }
    }

    private func performMarkMessagesAsReadBatch(
        messageIDs: [NSManagedObjectID],
        conversationID: NSManagedObjectID
    ) async {
        let context = coreDataStack.newBackgroundContext()
        let unreadInboxMessageCounter = self.unreadInboxMessageCounter

        let batchResult: (messageIds: [String], sourceConversationId: UUID?) = await context.perform {
            var markedIds: [String] = []
            let modificationDate = Date()
            var sourceConversationId: UUID?

            for messageID in messageIDs {
                guard let message = try? context.existingObject(with: messageID) as? Message else { continue }
                guard message.isUnread else { continue }

                message.isUnread = false
                message.localModifiedAt = modificationDate
                sourceConversationId = sourceConversationId ?? message.conversation?.id

                if !message.id.isEmpty {
                    markedIds.append(message.id)
                }
            }

            guard let conversation = try? context.existingObject(with: conversationID) as? Conversation else {
                context.rollback()
                return ([], sourceConversationId)
            }
            sourceConversationId = sourceConversationId ?? conversation.id

            do {
                conversation.inboxUnreadCount = Int32(
                    try unreadInboxMessageCounter(context, conversation)
                )
            } catch {
                context.rollback()
                Log.error(
                    "Aborting batch mark as read because the unread INBOX count failed",
                    category: .coreData,
                    error: error
                )
                return ([], sourceConversationId)
            }

            // Don't sync to Gmail if the local batch update didn't persist.
            guard context.saveOrLog(operation: "batch mark messages as read") else {
                return ([], sourceConversationId)
            }
            return (markedIds, sourceConversationId)
        }

        guard !batchResult.messageIds.isEmpty else { return }

        if let sourceConversationId = batchResult.sourceConversationId {
            await pendingActionsManager.queueConversationAction(
                type: .markRead,
                sourceConversationId: sourceConversationId,
                messageIds: batchResult.messageIds
            )
        } else {
            for messageId in batchResult.messageIds {
                await pendingActionsManager.queueAction(
                    type: .markRead,
                    messageId: messageId,
                    payload: nil
                )
            }
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
        let saved = coreDataStack.saveIfNeeded(context: coreDataStack.viewContext)

        if let conversation = message.conversation {
            updateConversationInboxStatus(conversation)
        }

        guard saved else {
            Log.error("Not queuing archive for message \(message.id): local save failed", category: .message)
            return
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

        let saved = coreDataStack.saveIfNeeded(context: context)
        Log.debug("Removed INBOX label from \(removedCount) messages, saved context", category: .message)

        updateConversationInboxStatus(conversation)
        Log.debug("Updated conversation inbox status - hasInbox: \(conversation.hasInbox)", category: .message)

        guard saved else {
            Log.error("Not queuing archiveConversation for '\(conversation.id)': local save failed", category: .message)
            return
        }

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
        let saved = coreDataStack.saveIfNeeded(context: context)
        Log.info("Batch archived \(conversations.count) conversations (\(allMessageIds.count) messages)", category: .message)

        guard saved else {
            Log.error("Not queuing batch archiveConversation: local save failed", category: .message)
            return
        }

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
        let saved = coreDataStack.saveIfNeeded(context: context)
        Log.info("Batch reported \(conversations.count) conversations as spam (\(allMessageIds.count) messages)", category: .message)

        guard saved else {
            Log.error("Not queuing batch reportSpam: local save failed", category: .message)
            return
        }

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

        let saved = coreDataStack.saveIfNeeded(context: context)
        Log.debug("Marked \(messageIds.count) messages for spam, removed INBOX labels, archived conversation", category: .message)

        guard saved else {
            Log.error("Not queuing reportSpam for '\(conversation.id)': local save failed", category: .message)
            return
        }

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

    private func snapshotUnreadInboxMessageObjectIDs(
        for conversation: Conversation,
        context: NSManagedObjectContext
    ) -> [NSManagedObjectID] {
        let request = NSFetchRequest<NSManagedObjectID>(entityName: "Message")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "conversation == %@", conversation),
            NSPredicate(format: "ANY labels.id == %@", "INBOX"),
            NSPredicate(format: "isUnread == YES")
        ])
        request.fetchBatchSize = 50
        request.resultType = .managedObjectIDResultType

        do {
            return try context.fetch(request)
        } catch {
            Log.error("Failed to snapshot unread INBOX message IDs for conversation", category: .coreData, error: error)
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

    nonisolated private static func countUnreadInboxMessages(
        in context: NSManagedObjectContext,
        conversation: Conversation
    ) throws -> Int {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "conversation == %@", conversation),
            NSPredicate(format: "ANY labels.id == %@", "INBOX"),
            NSPredicate(format: "isUnread == YES")
        ])
        return try context.count(for: request)
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
        let saved = coreDataStack.saveIfNeeded(context: coreDataStack.viewContext, caller: "updateStarState")

        guard saved else {
            Log.error("Not queuing \(actionType.rawValue) for message \(message.id): local save failed", category: .message)
            return
        }

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
