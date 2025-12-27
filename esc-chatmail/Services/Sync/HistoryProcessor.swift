import Foundation
import CoreData

/// Handles processing Gmail history records for incremental sync
final class HistoryProcessor: @unchecked Sendable {
    private let coreDataStack: CoreDataStack

    /// Serial queue to protect access to modifiedConversationIDs
    private let modifiedConversationsQueue = DispatchQueue(label: "com.esc.chatmail.historyProcessor.modifiedConversations")

    /// Tracks conversation IDs modified during history processing
    private var modifiedConversationIDs: Set<NSManagedObjectID> = []

    init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    /// Returns and clears the set of modified conversation IDs
    func getAndClearModifiedConversations() -> Set<NSManagedObjectID> {
        return modifiedConversationsQueue.sync {
            let result = modifiedConversationIDs
            modifiedConversationIDs.removeAll()
            return result
        }
    }

    /// Tracks a conversation as modified
    private func trackModifiedConversation(_ conversation: Conversation) {
        _ = modifiedConversationsQueue.sync {
            modifiedConversationIDs.insert(conversation.objectID)
        }
    }

    /// Tracks a conversation as modified (public version for reconciliation)
    func trackModifiedConversationForReconciliation(_ conversation: Conversation) {
        trackModifiedConversation(conversation)
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
    func extractNewMessageIds(from records: [HistoryRecord]) -> [String] {
        var messageIds: [String] = []

        for record in records {
            if let messagesAdded = record.messagesAdded {
                print("📬 History record \(record.id): \(messagesAdded.count) new messages")
                for added in messagesAdded {
                    // Skip spam messages
                    if let labelIds = added.message.labelIds, labelIds.contains("SPAM") {
                        print("   ⏭️ Skipping spam: \(added.message.id)")
                        continue
                    }
                    print("   ✅ Will fetch: \(added.message.id)")
                    messageIds.append(added.message.id)
                }
            }
        }

        print("📊 Total new messages to fetch: \(messageIds.count)")
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
                    print("Failed to fetch message for deletion \(messageId): \(error.localizedDescription)")
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

        for added in labelsAdded {
            let messageId = added.message.id
            let labelIds = added.labelIds
            let hasUnread = labelIds.contains("UNREAD")

            await context.perform {
                let request = Message.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", messageId)
                do {
                    guard let message = try context.fetch(request).first else {
                        // Message not found locally - this is normal for messages we haven't synced
                        return
                    }

                    // Conflict resolution: skip if message has pending local changes
                    if self.hasConflict(message: message, syncStartTime: syncStartTime) {
                        print("Skipping server label addition for message \(messageId) - local changes pending")
                        return
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
                            print("Warning: Only found \(labels.count) of \(labelIds.count) labels for message \(messageId)")
                        }
                    } catch {
                        print("Failed to fetch labels for message \(messageId): \(error.localizedDescription)")
                    }

                    if hasUnread {
                        message.isUnread = true
                    }

                    // Track conversation for rollup update (handles hasInbox changes)
                    if let conversation = message.conversation {
                        self.trackModifiedConversation(conversation)
                    }
                } catch {
                    print("Failed to fetch message for label addition \(messageId): \(error.localizedDescription)")
                }
            }
        }
    }

    private func processLabelRemovals(
        _ labelsRemoved: [HistoryLabelRemoved]?,
        in context: NSManagedObjectContext,
        syncStartTime: Date?
    ) async {
        guard let labelsRemoved = labelsRemoved else { return }

        print("🏷️ [HistoryProcessor] Processing \(labelsRemoved.count) label removals")

        for removed in labelsRemoved {
            let messageId = removed.message.id
            let labelIds = removed.labelIds
            let removesUnread = labelIds.contains("UNREAD")
            let removesInbox = labelIds.contains("INBOX")

            print("🏷️ [HistoryProcessor] Label removal: messageId=\(messageId), labels=\(labelIds), removesInbox=\(removesInbox)")

            await context.perform {
                let request = Message.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", messageId)
                do {
                    guard let message = try context.fetch(request).first else {
                        // Message not found locally - this is normal for messages we haven't synced
                        print("🏷️ [HistoryProcessor] Message \(messageId) not found locally - skipping")
                        return
                    }

                    print("🏷️ [HistoryProcessor] Found local message \(messageId), applying label removal")

                    // Conflict resolution: skip if message has pending local changes
                    if self.hasConflict(message: message, syncStartTime: syncStartTime) {
                        print("Skipping server label removal for message \(messageId) - local changes pending")
                        return
                    }

                    // Fetch labels by ID
                    let labelRequest = Label.fetchRequest()
                    labelRequest.predicate = NSPredicate(format: "id IN %@", labelIds)
                    do {
                        let labels = try context.fetch(labelRequest)
                        for label in labels {
                            message.removeFromLabels(label)
                            print("🏷️ [HistoryProcessor] Removed label '\(label.id)' from message \(messageId)")
                        }
                    } catch {
                        print("Failed to fetch labels for removal on message \(messageId): \(error.localizedDescription)")
                    }

                    if removesUnread {
                        message.isUnread = false
                    }

                    // Track conversation for rollup update (handles hasInbox changes)
                    if let conversation = message.conversation {
                        self.trackModifiedConversation(conversation)
                        print("🏷️ [HistoryProcessor] Tracked conversation \(conversation.id.uuidString) for rollup update")
                    }
                } catch {
                    print("Failed to fetch message for label removal \(messageId): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Maximum age for local modifications before they're considered stale
    /// If a local modification is older than this, we allow server updates
    /// This prevents local changes from blocking server updates indefinitely
    private static let maxLocalModificationAge: TimeInterval = 300 // 5 minutes

    /// Check if a message has local modifications that haven't been synced yet
    private nonisolated func hasConflict(message: Message, syncStartTime: Date?) -> Bool {
        guard let syncStartTime = syncStartTime else { return false }
        guard let localModifiedAt = message.value(forKey: "localModifiedAt") as? Date else { return false }

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
            print("⚠️ [SyncCorrectness] Local modification is stale (age: \(Int(modificationAge))s), allowing server update")
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
                    print("Failed to fetch message \(messageId) for clearing local modifications: \(error.localizedDescription)")
                }
            }

            do {
                if context.hasChanges {
                    try context.save()
                    print("Cleared local modifications for \(successCount) messages")
                }
            } catch {
                print("Failed to save after clearing local modifications: \(error.localizedDescription)")
            }
        }
    }
}
