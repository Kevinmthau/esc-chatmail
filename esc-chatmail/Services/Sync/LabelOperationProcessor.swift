import Foundation
import CoreData

/// Protocol for label change items (additions or removals)
///
/// Both `HistoryLabelAdded` and `HistoryLabelRemoved` conform to this protocol.
protocol LabelChangeItem {
    /// The message affected by this label change
    var message: MessageListItem { get }
    /// The label IDs being added or removed
    var labelIds: [String] { get }
}

extension HistoryLabelAdded: LabelChangeItem {}
extension HistoryLabelRemoved: LabelChangeItem {}

/// Unified processor for label additions and removals
///
/// Eliminates ~100 lines of duplicate code between:
/// - `HistoryProcessor.processLabelAdditions()`
/// - `HistoryProcessor.processLabelRemovals()`
///
/// Both methods share 70%+ identical code for:
/// - Collecting message/label IDs
/// - Batch fetching messages and labels
/// - Creating dictionaries for O(1) lookup
/// - Processing with conflict resolution
struct LabelOperationProcessor {

    /// The type of label operation to perform
    enum Operation {
        case add
        case remove
    }

    /// Maximum age for local modifications before they're considered stale
    /// Uses the centralized config value from SyncConfig
    private static var maxLocalModificationAge: TimeInterval {
        SyncConfig.maxLocalModificationAge
    }

    /// Processes label changes (additions or removals) for history records
    ///
    /// - Parameters:
    ///   - items: Array of label change items (HistoryLabelAdded or HistoryLabelRemoved)
    ///   - operation: Whether to add or remove labels
    ///   - context: Core Data context for database operations
    ///   - syncStartTime: When sync started (for conflict resolution)
    /// - Returns: Array of modified conversation ObjectIDs for rollup updates
    static func process<T: LabelChangeItem>(
        items: [T]?,
        operation: Operation,
        in context: NSManagedObjectContext,
        syncStartTime: Date?
    ) async -> [NSManagedObjectID] {
        guard let items = items, !items.isEmpty else { return [] }

        if operation == .remove {
            Log.debug("Processing \(items.count) label removals", category: .sync)
        }

        // Collect all message IDs and label IDs upfront for batch fetching
        let allMessageIds = Set(items.map { $0.message.id })
        let allLabelIds = Set(items.flatMap { $0.labelIds })

        return await context.perform {
            // Batch fetch all messages
            let messageRequest = Message.fetchRequest()
            messageRequest.predicate = NSPredicate(format: "id IN %@", allMessageIds)
            messageRequest.relationshipKeyPathsForPrefetching = ["labels", "conversation"]

            guard let messages = try? context.fetch(messageRequest) else {
                Log.error("Failed to batch fetch messages for label \(operation)", category: .sync)
                return []
            }

            // Create dictionary for O(1) lookup
            let messageDict = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })

            // Batch fetch all labels
            let labelRequest = Label.fetchRequest()
            labelRequest.predicate = NSPredicate(format: "id IN %@", allLabelIds)

            guard let labels = try? context.fetch(labelRequest) else {
                Log.error("Failed to batch fetch labels for \(operation)", category: .sync)
                return []
            }

            let labelDict = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) })

            // Process each item using pre-fetched objects
            var modifiedIDs: [NSManagedObjectID] = []

            for item in items {
                let messageId = item.message.id
                let labelIds = item.labelIds

                guard let message = messageDict[messageId] else {
                    // Message not found locally - this is normal for messages we haven't synced
                    if operation == .remove {
                        Log.debug("Message \(messageId) not found locally - skipping", category: .sync)
                    }
                    continue
                }

                if operation == .remove {
                    Log.debug("Found local message \(messageId), applying label removal", category: .sync)
                }

                // Conflict resolution: skip if message has pending local changes
                if hasConflict(message: message, syncStartTime: syncStartTime) {
                    Log.debug("Skipping server label \(operation) for message \(messageId) - local changes pending", category: .sync)
                    continue
                }

                // Apply label changes using pre-fetched label objects
                var foundLabels = 0
                for labelId in labelIds {
                    if let label = labelDict[labelId] {
                        switch operation {
                        case .add:
                            message.addToLabels(label)
                        case .remove:
                            message.removeFromLabels(label)
                            Log.debug("Removed label '\(label.id)' from message \(messageId)", category: .sync)
                        }
                        foundLabels += 1
                    }
                }

                if operation == .add && foundLabels != labelIds.count {
                    Log.warning("Only found \(foundLabels) of \(labelIds.count) labels for message \(messageId)", category: .sync)
                }

                // Handle UNREAD label specially
                let hasUnreadLabel = labelIds.contains("UNREAD")
                if hasUnreadLabel {
                    message.isUnread = (operation == .add)
                }

                if let conversation = message.conversation {
                    if operation == .remove {
                        Log.debug("Tracked conversation \(conversation.id.uuidString) for rollup update", category: .sync)
                    }
                    modifiedIDs.append(conversation.objectID)
                }
            }

            return modifiedIDs
        }
    }

    /// Check if a message has local modifications that haven't been synced yet
    ///
    /// This prevents server updates from overwriting local changes.
    /// However, if the local modification is too old (stale), we allow the server update.
    private static func hasConflict(message: Message, syncStartTime: Date?) -> Bool {
        guard let syncStartTime = syncStartTime else { return false }
        guard let localModifiedAt = message.localModifiedAtValue else { return false }

        // If the message was modified locally after the sync started,
        // it means there's a pending local change that should take precedence
        let hasPendingChange = localModifiedAt > syncStartTime

        // However, if the local modification is too old, consider it stale
        // This prevents local changes from blocking server updates indefinitely
        let now = Date()
        let modificationAge = now.timeIntervalSince(localModifiedAt)
        let isStaleModification = modificationAge > maxLocalModificationAge

        if hasPendingChange && isStaleModification {
            Log.warning("Local modification is stale (age: \(Int(modificationAge))s), allowing server update", category: .sync)
            return false
        }

        return hasPendingChange
    }
}
