import Foundation
import CoreData

/// Handles processing Gmail history records for incremental sync
actor HistoryProcessor {
    private let coreDataStack: CoreDataStack

    /// Tracks conversation IDs modified during history processing
    /// Actor isolation provides thread safety
    private var modifiedConversationIDs: Set<NSManagedObjectID> = []

    init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    /// Returns and clears the set of modified conversation IDs
    func getAndClearModifiedConversations() -> Set<NSManagedObjectID> {
        let result = modifiedConversationIDs
        modifiedConversationIDs.removeAll()
        return result
    }

    /// Tracks a conversation as modified by its objectID
    private func trackModifiedConversation(_ objectID: NSManagedObjectID) {
        modifiedConversationIDs.insert(objectID)
    }

    /// Tracks multiple conversations as modified
    private func trackModifiedConversations(_ objectIDs: [NSManagedObjectID]) {
        for objectID in objectIDs {
            modifiedConversationIDs.insert(objectID)
        }
    }

    /// Tracks a conversation as modified (public version for reconciliation)
    func trackModifiedConversationForReconciliation(_ conversation: Conversation) {
        modifiedConversationIDs.insert(conversation.objectID)
    }

    /// Processes a history record for lightweight operations (label changes and deletions)
    /// - Parameters:
    ///   - record: The history record to process
    ///   - context: The Core Data context
    ///   - syncStartTime: When the sync started (for conflict resolution)
    func processLightweightOperations(
        _ record: HistoryRecord,
        in context: NSManagedObjectContext,
        syncStartTime: Date? = nil
    ) async {
        // Handle message deletions - always apply, deletions are authoritative
        await processMessageDeletions(record.messagesDeleted, in: context)

        // Handle label additions with conflict resolution
        await processLabelAdditions(record.labelsAdded, in: context, syncStartTime: syncStartTime)

        // Handle label removals with conflict resolution
        await processLabelRemovals(record.labelsRemoved, in: context, syncStartTime: syncStartTime)
    }

    /// Extracts message IDs that need to be fetched from history records
    /// - Parameter records: Array of history records
    /// - Returns: Array of message IDs (excluding spam)
    nonisolated func extractNewMessageIds(from records: [HistoryRecord]) -> [String] {
        var messageIds: [String] = []

        for record in records {
            if let messagesAdded = record.messagesAdded {
                Log.debug("History record \(record.id): \(messagesAdded.count) new messages", category: .sync)
                for added in messagesAdded {
                    // Skip spam messages
                    if let labelIds = added.message.labelIds, labelIds.contains("SPAM") {
                        Log.debug("Skipping spam: \(added.message.id)", category: .sync)
                        continue
                    }
                    Log.debug("Will fetch: \(added.message.id)", category: .sync)
                    messageIds.append(added.message.id)
                }
            }
        }

        Log.debug("Total new messages to fetch: \(messageIds.count)", category: .sync)
        return messageIds
    }

    // MARK: - Private Methods

    private func processMessageDeletions(
        _ messagesDeleted: [HistoryMessageDeleted]?,
        in context: NSManagedObjectContext
    ) async {
        guard let messagesDeleted = messagesDeleted else { return }

        let messageIds = messagesDeleted.map { $0.message.id }
        await context.perform {
            for messageId in messageIds {
                let request = Message.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", messageId)
                do {
                    if let message = try context.fetch(request).first {
                        context.delete(message)
                    }
                } catch {
                    Log.error("Failed to fetch message for deletion \(messageId)", category: .sync, error: error)
                }
            }
        }
    }

    private func processLabelAdditions(
        _ labelsAdded: [HistoryLabelAdded]?,
        in context: NSManagedObjectContext,
        syncStartTime: Date?
    ) async {
        guard let labelsAdded = labelsAdded else { return }

        var modifiedObjectIDs: [NSManagedObjectID] = []

        for added in labelsAdded {
            let messageId = added.message.id
            let labelIds = added.labelIds
            let hasUnread = labelIds.contains("UNREAD")

            let objectID: NSManagedObjectID? = await context.perform {
                let request = Message.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", messageId)
                do {
                    guard let message = try context.fetch(request).first else {
                        // Message not found locally - this is normal for messages we haven't synced
                        return nil
                    }

                    // Conflict resolution: skip if message has pending local changes
                    if self.hasConflict(message: message, syncStartTime: syncStartTime) {
                        Log.debug("Skipping server label addition for message \(messageId) - local changes pending", category: .sync)
                        return nil
                    }

                    // Fetch labels by ID
                    let labelRequest = Label.fetchRequest()
                    labelRequest.predicate = NSPredicate(format: "id IN %@", labelIds)
                    do {
                        let labels = try context.fetch(labelRequest)
                        for label in labels {
                            message.addToLabels(label)
                        }
                        if labels.count != labelIds.count {
                            Log.warning("Only found \(labels.count) of \(labelIds.count) labels for message \(messageId)", category: .sync)
                        }
                    } catch {
                        Log.error("Failed to fetch labels for message \(messageId)", category: .sync, error: error)
                    }

                    if hasUnread {
                        message.isUnread = true
                    }

                    // Return conversation objectID for tracking outside the closure
                    return message.conversation?.objectID
                } catch {
                    Log.error("Failed to fetch message for label addition \(messageId)", category: .sync, error: error)
                    return nil
                }
            }

            if let objectID = objectID {
                modifiedObjectIDs.append(objectID)
            }
        }

        // Track all modified conversations (actor-isolated)
        trackModifiedConversations(modifiedObjectIDs)
    }

    private func processLabelRemovals(
        _ labelsRemoved: [HistoryLabelRemoved]?,
        in context: NSManagedObjectContext,
        syncStartTime: Date?
    ) async {
        guard let labelsRemoved = labelsRemoved else { return }

        Log.debug("Processing \(labelsRemoved.count) label removals", category: .sync)

        var modifiedObjectIDs: [NSManagedObjectID] = []

        for removed in labelsRemoved {
            let messageId = removed.message.id
            let labelIds = removed.labelIds
            let removesUnread = labelIds.contains("UNREAD")
            let removesInbox = labelIds.contains("INBOX")

            Log.debug("Label removal: messageId=\(messageId), labels=\(labelIds), removesInbox=\(removesInbox)", category: .sync)

            let objectID: NSManagedObjectID? = await context.perform {
                let request = Message.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", messageId)
                do {
                    guard let message = try context.fetch(request).first else {
                        // Message not found locally - this is normal for messages we haven't synced
                        Log.debug("Message \(messageId) not found locally - skipping", category: .sync)
                        return nil
                    }

                    Log.debug("Found local message \(messageId), applying label removal", category: .sync)

                    // Conflict resolution: skip if message has pending local changes
                    if self.hasConflict(message: message, syncStartTime: syncStartTime) {
                        Log.debug("Skipping server label removal for message \(messageId) - local changes pending", category: .sync)
                        return nil
                    }

                    // Fetch labels by ID
                    let labelRequest = Label.fetchRequest()
                    labelRequest.predicate = NSPredicate(format: "id IN %@", labelIds)
                    do {
                        let labels = try context.fetch(labelRequest)
                        for label in labels {
                            message.removeFromLabels(label)
                            Log.debug("Removed label '\(label.id)' from message \(messageId)", category: .sync)
                        }
                    } catch {
                        Log.error("Failed to fetch labels for removal on message \(messageId)", category: .sync, error: error)
                    }

                    if removesUnread {
                        message.isUnread = false
                    }

                    // Return conversation objectID for tracking outside the closure
                    if let conversation = message.conversation {
                        Log.debug("Tracked conversation \(conversation.id.uuidString) for rollup update", category: .sync)
                        return conversation.objectID
                    }
                    return nil
                } catch {
                    Log.error("Failed to fetch message for label removal \(messageId)", category: .sync, error: error)
                    return nil
                }
            }

            if let objectID = objectID {
                modifiedObjectIDs.append(objectID)
            }
        }

        // Track all modified conversations (actor-isolated)
        trackModifiedConversations(modifiedObjectIDs)
    }

    /// Maximum age for local modifications before they're considered stale
    /// If a local modification is older than this, we allow server updates
    /// This prevents local changes from blocking server updates indefinitely
    private static let maxLocalModificationAge: TimeInterval = 300 // 5 minutes

    /// Check if a message has local modifications that haven't been synced yet
    private nonisolated func hasConflict(message: Message, syncStartTime: Date?) -> Bool {
        guard let syncStartTime = syncStartTime else { return false }
        guard let localModifiedAt = message.localModifiedAtValue else { return false }

        // If the message was modified locally after the sync started,
        // it means there's a pending local change that should take precedence
        let hasPendingChange = localModifiedAt > syncStartTime

        // However, if the local modification is too old, consider it stale
        // This prevents local changes from blocking server updates indefinitely
        // This can happen if the action failed to sync to the server
        let now = Date()
        let modificationAge = now.timeIntervalSince(localModifiedAt)
        let isStaleModification = modificationAge > Self.maxLocalModificationAge

        if hasPendingChange && isStaleModification {
            Log.warning("Local modification is stale (age: \(Int(modificationAge))s), allowing server update", category: .sync)
            return false
        }

        return hasPendingChange
    }

    /// Clear localModifiedAt for messages whose pending actions have been processed
    func clearLocalModifications(for messageIds: [String]) async {
        let context = coreDataStack.newBackgroundContext()
        await context.perform {
            var successCount = 0
            for messageId in messageIds {
                let request = Message.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", messageId)
                do {
                    if let message = try context.fetch(request).first {
                        message.setValue(nil, forKey: "localModifiedAt")
                        successCount += 1
                    }
                } catch {
                    Log.error("Failed to fetch message \(messageId) for clearing local modifications", category: .sync, error: error)
                }
            }

            do {
                if context.hasChanges {
                    try context.save()
                    Log.debug("Cleared local modifications for \(successCount) messages", category: .sync)
                }
            } catch {
                Log.error("Failed to save after clearing local modifications", category: .sync, error: error)
            }
        }
    }
}
