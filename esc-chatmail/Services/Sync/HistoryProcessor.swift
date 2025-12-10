import Foundation
import CoreData

/// Handles processing Gmail history records for incremental sync
final class HistoryProcessor: @unchecked Sendable {
    private let coreDataStack: CoreDataStack

    init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
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
                for added in messagesAdded {
                    // Skip spam messages
                    if let labelIds = added.message.labelIds, labelIds.contains("SPAM") {
                        continue
                    }
                    messageIds.append(added.message.id)
                }
            }
        }

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
                if let message = try? context.fetch(request).first {
                    context.delete(message)
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
                if let message = try? context.fetch(request).first {
                    // Conflict resolution: skip if message has pending local changes
                    if self.hasConflict(message: message, syncStartTime: syncStartTime) {
                        print("Skipping server label addition for message \(messageId) - local changes pending")
                        return
                    }

                    // Fetch labels by ID
                    let labelRequest = Label.fetchRequest()
                    labelRequest.predicate = NSPredicate(format: "id IN %@", labelIds)
                    if let labels = try? context.fetch(labelRequest) {
                        for label in labels {
                            message.addToLabels(label)
                        }
                    }
                    if hasUnread {
                        message.isUnread = true
                    }
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

        for removed in labelsRemoved {
            let messageId = removed.message.id
            let labelIds = removed.labelIds
            let removesUnread = labelIds.contains("UNREAD")

            await context.perform {
                let request = Message.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", messageId)
                if let message = try? context.fetch(request).first {
                    // Conflict resolution: skip if message has pending local changes
                    if self.hasConflict(message: message, syncStartTime: syncStartTime) {
                        print("Skipping server label removal for message \(messageId) - local changes pending")
                        return
                    }

                    // Fetch labels by ID
                    let labelRequest = Label.fetchRequest()
                    labelRequest.predicate = NSPredicate(format: "id IN %@", labelIds)
                    if let labels = try? context.fetch(labelRequest) {
                        for label in labels {
                            message.removeFromLabels(label)
                        }
                    }
                    if removesUnread {
                        message.isUnread = false
                    }
                }
            }
        }
    }

    /// Check if a message has local modifications that haven't been synced yet
    private nonisolated func hasConflict(message: Message, syncStartTime: Date?) -> Bool {
        guard let syncStartTime = syncStartTime else { return false }
        guard let localModifiedAt = message.value(forKey: "localModifiedAt") as? Date else { return false }

        // If the message was modified locally after the sync started,
        // it means there's a pending local change that should take precedence
        return localModifiedAt > syncStartTime
    }

    /// Clear localModifiedAt for messages whose pending actions have been processed
    func clearLocalModifications(for messageIds: [String]) async {
        let context = coreDataStack.newBackgroundContext()
        await context.perform {
            for messageId in messageIds {
                let request = Message.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", messageId)
                if let message = try? context.fetch(request).first {
                    message.setValue(nil, forKey: "localModifiedAt")
                }
            }
            try? context.save()
        }
    }
}
