import Foundation
import CoreData

extension HistoryProcessor {
    /// Maximum age for local modifications before they're considered stale
    /// If a local modification is older than this, we allow server updates
    /// This prevents local changes from blocking server updates indefinitely
    /// Note: 30 minutes allows for slow networks and app suspensions while still
    /// eventually allowing server updates if the pending action truly failed
    static let maxLocalModificationAge: TimeInterval = 1800 // 30 minutes

    func processLabelAdditions(
        _ labelsAdded: [HistoryLabelAdded]?,
        in context: NSManagedObjectContext,
        syncStartTime: Date?
    ) async {
        guard let labelsAdded = labelsAdded, !labelsAdded.isEmpty else { return }

        // Collect all message IDs and label IDs upfront for batch fetching
        let allMessageIds = Set(labelsAdded.map { $0.message.id })
        let allLabelIds = Set(labelsAdded.flatMap { $0.labelIds })

        let modifiedObjectIDs: [NSManagedObjectID] = await context.perform {
            // Batch fetch all messages
            let messageRequest = Message.fetchRequest()
            messageRequest.predicate = NSPredicate(format: "id IN %@", allMessageIds)
            messageRequest.relationshipKeyPathsForPrefetching = ["labels", "conversation"]

            guard let messages = try? context.fetch(messageRequest) else {
                Log.error("Failed to batch fetch messages for label additions", category: .sync)
                return []
            }

            // Create dictionary for O(1) lookup
            let messageDict = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })

            // Batch fetch all labels
            let labelRequest = Label.fetchRequest()
            labelRequest.predicate = NSPredicate(format: "id IN %@", allLabelIds)

            guard let labels = try? context.fetch(labelRequest) else {
                Log.error("Failed to batch fetch labels for additions", category: .sync)
                return []
            }

            let labelDict = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) })

            // Process each addition using pre-fetched objects
            var modifiedIDs: [NSManagedObjectID] = []

            for added in labelsAdded {
                let messageId = added.message.id
                let labelIds = added.labelIds
                let hasUnread = labelIds.contains("UNREAD")

                guard let message = messageDict[messageId] else {
                    // Message not found locally - this is normal for messages we haven't synced
                    continue
                }

                // Conflict resolution: skip if message has pending local changes
                if self.hasConflict(message: message, syncStartTime: syncStartTime) {
                    Log.debug("Skipping server label addition for message \(messageId) - local changes pending", category: .sync)
                    continue
                }

                // Add labels using pre-fetched label objects
                var foundLabels = 0
                for labelId in labelIds {
                    if let label = labelDict[labelId] {
                        message.addToLabels(label)
                        foundLabels += 1
                    }
                }
                if foundLabels != labelIds.count {
                    Log.warning("Only found \(foundLabels) of \(labelIds.count) labels for message \(messageId)", category: .sync)
                }

                if hasUnread {
                    message.isUnread = true
                }

                if let conversationID = message.conversation?.objectID {
                    modifiedIDs.append(conversationID)
                }
            }

            return modifiedIDs
        }

        // Track all modified conversations (actor-isolated)
        trackModifiedConversations(modifiedObjectIDs)
    }

    func processLabelRemovals(
        _ labelsRemoved: [HistoryLabelRemoved]?,
        in context: NSManagedObjectContext,
        syncStartTime: Date?
    ) async {
        guard let labelsRemoved = labelsRemoved, !labelsRemoved.isEmpty else { return }

        Log.debug("Processing \(labelsRemoved.count) label removals", category: .sync)

        // Collect all message IDs and label IDs upfront for batch fetching
        let allMessageIds = Set(labelsRemoved.map { $0.message.id })
        let allLabelIds = Set(labelsRemoved.flatMap { $0.labelIds })

        let modifiedObjectIDs: [NSManagedObjectID] = await context.perform {
            // Batch fetch all messages
            let messageRequest = Message.fetchRequest()
            messageRequest.predicate = NSPredicate(format: "id IN %@", allMessageIds)
            messageRequest.relationshipKeyPathsForPrefetching = ["labels", "conversation"]

            guard let messages = try? context.fetch(messageRequest) else {
                Log.error("Failed to batch fetch messages for label removals", category: .sync)
                return []
            }

            // Create dictionary for O(1) lookup
            let messageDict = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })

            // Batch fetch all labels
            let labelRequest = Label.fetchRequest()
            labelRequest.predicate = NSPredicate(format: "id IN %@", allLabelIds)

            guard let labels = try? context.fetch(labelRequest) else {
                Log.error("Failed to batch fetch labels for removals", category: .sync)
                return []
            }

            let labelDict = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) })

            // Process each removal using pre-fetched objects
            var modifiedIDs: [NSManagedObjectID] = []

            for removed in labelsRemoved {
                let messageId = removed.message.id
                let labelIds = removed.labelIds
                let removesUnread = labelIds.contains("UNREAD")

                guard let message = messageDict[messageId] else {
                    // Message not found locally - this is normal for messages we haven't synced
                    Log.debug("Message \(messageId) not found locally - skipping", category: .sync)
                    continue
                }

                Log.debug("Found local message \(messageId), applying label removal", category: .sync)

                // Conflict resolution: skip if message has pending local changes
                if self.hasConflict(message: message, syncStartTime: syncStartTime) {
                    Log.debug("Skipping server label removal for message \(messageId) - local changes pending", category: .sync)
                    continue
                }

                // Remove labels using pre-fetched label objects
                for labelId in labelIds {
                    if let label = labelDict[labelId] {
                        message.removeFromLabels(label)
                        Log.debug("Removed label '\(label.id)' from message \(messageId)", category: .sync)
                    }
                }

                if removesUnread {
                    message.isUnread = false
                }

                if let conversation = message.conversation {
                    Log.debug("Tracked conversation \(conversation.id.uuidString) for rollup update", category: .sync)
                    modifiedIDs.append(conversation.objectID)
                }
            }

            return modifiedIDs
        }

        // Track all modified conversations (actor-isolated)
        trackModifiedConversations(modifiedObjectIDs)
    }

    /// Check if a message has local modifications that haven't been synced yet
    nonisolated func hasConflict(message: Message, syncStartTime: Date?) -> Bool {
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
}
