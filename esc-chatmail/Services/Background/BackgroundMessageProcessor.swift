import Foundation
import CoreData

/// Handles message fetching, storing, and deletion for background sync
final class BackgroundMessageProcessor {
    private let coreDataStack: CoreDataStack
    @MainActor private var syncEngine: SyncEngine { SyncEngine.shared }
    @MainActor private var apiClient: GmailAPIClient { GmailAPIClient.shared }

    init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    /// Processes history changes and categorizes them
    func processHistoryChanges(histories: [HistoryRecord]) async {
        let context = coreDataStack.newBackgroundContext()

        var messagesToFetch: Set<String> = []
        var messagesToDelete: Set<String> = []
        var messageLabelsToUpdate: [String: [String]] = [:]

        for history in histories {
            if let messagesAdded = history.messagesAdded {
                for messageAdded in messagesAdded {
                    // Skip spam messages
                    if let labelIds = messageAdded.message.labelIds, labelIds.contains("SPAM") {
                        Log.debug("Skipping spam message from history: \(messageAdded.message.id)", category: .background)
                        continue
                    }
                    messagesToFetch.insert(messageAdded.message.id)
                }
            }

            if let messagesDeleted = history.messagesDeleted {
                for messageDeleted in messagesDeleted {
                    messagesToDelete.insert(messageDeleted.message.id)
                }
            }

            if let labelsAdded = history.labelsAdded {
                for labelAdded in labelsAdded {
                    let messageId = labelAdded.message.id
                    var labels = messageLabelsToUpdate[messageId] ?? []
                    labels.append(contentsOf: labelAdded.labelIds)
                    messageLabelsToUpdate[messageId] = labels
                }
            }

            if let labelsRemoved = history.labelsRemoved {
                for labelRemoved in labelsRemoved {
                    messagesToFetch.insert(labelRemoved.message.id)
                }
            }
        }

        await deleteMessages(messageIds: Array(messagesToDelete), in: context)

        if !messagesToFetch.isEmpty {
            await fetchAndStoreMessages(messageIds: Array(messagesToFetch))
        }

        coreDataStack.saveIfNeeded(context: context)
    }

    /// Fetches messages from the API and stores them in Core Data
    func fetchAndStoreMessages(messageIds: [String]) async {
        let context = coreDataStack.newBackgroundContext()

        // Prefetch label IDs for efficient lookups (IDs are Sendable, safe to pass across async boundaries)
        let labelIds = await syncEngine.prefetchLabelIdsForBackground(in: context)

        let batchSize = 10
        var successCount = 0
        var failedCount = 0

        for batch in messageIds.chunked(into: batchSize) {
            await withTaskGroup(of: (String, Result<GmailMessage, Error>).self) { group in
                for messageId in batch {
                    group.addTask { [self] in
                        do {
                            let message = try await apiClient.getMessage(id: messageId)
                            return (messageId, .success(message))
                        } catch {
                            return (messageId, .failure(error))
                        }
                    }
                }

                for await (messageId, result) in group {
                    switch result {
                    case .success(let message):
                        await syncEngine.saveMessage(message, labelIds: labelIds, in: context)
                        successCount += 1
                    case .failure(let error):
                        failedCount += 1
                        Log.warning("Failed to fetch message \(messageId) in background: \(error.localizedDescription)", category: .background)
                    }
                }
            }
        }

        if failedCount > 0 {
            Log.info("Background sync: fetched \(successCount) messages, \(failedCount) failed", category: .background)
        }

        await syncEngine.updateConversationRollups(in: context)

        do {
            if context.hasChanges {
                try context.save()
            }
        } catch {
            Log.error("Failed to save background sync context: \(error.localizedDescription)", category: .background)
        }
    }

    /// Deletes messages from Core Data
    func deleteMessages(messageIds: [String], in context: NSManagedObjectContext) async {
        await context.perform {
            for messageId in messageIds {
                let fetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", messageId)

                do {
                    let messages = try context.fetch(fetchRequest)
                    for message in messages {
                        context.delete(message)
                    }
                } catch {
                    Log.error("Failed to delete message \(messageId)", category: .background, error: error)
                }
            }
        }
    }
}
