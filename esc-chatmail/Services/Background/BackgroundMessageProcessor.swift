import Foundation
import CoreData

protocol BackgroundSyncMessageCoordinating: AnyObject, Sendable {
    func prefetchLabelIdsForBackground(in context: NSManagedObjectContext) async -> Set<String>
    func saveMessage(_ gmailMessage: GmailMessage, labelIds: Set<String>?, in context: NSManagedObjectContext) async
    func updateConversationRollups(in context: NSManagedObjectContext) async
}

extension SyncEngine: BackgroundSyncMessageCoordinating {}

/// Categorized history changes for background sync processing.
struct BackgroundHistoryChangeSet {
    let messageIdsToFetch: Set<String>
    let messageIdsToDelete: Set<String>
}

/// Handles message fetching, storing, and deletion for background sync
final class BackgroundMessageProcessor {
    private let makeBackgroundContext: @Sendable () -> NSManagedObjectContext
    private let saveContext: @Sendable (NSManagedObjectContext) -> Bool
    private let apiClientProvider: @MainActor @Sendable () -> GmailAPIClientProtocol
    private let syncCoordinatorProvider: @MainActor @Sendable () -> BackgroundSyncMessageCoordinating

    @MainActor private var apiClient: GmailAPIClientProtocol {
        apiClientProvider()
    }

    @MainActor private var syncCoordinator: BackgroundSyncMessageCoordinating {
        syncCoordinatorProvider()
    }

    init(
        coreDataStack: CoreDataStack = .shared,
        apiClient: GmailAPIClientProtocol? = nil,
        syncCoordinator: BackgroundSyncMessageCoordinating? = nil
    ) {
        self.makeBackgroundContext = { coreDataStack.newBackgroundContext() }
        self.saveContext = { coreDataStack.saveIfNeeded(context: $0) }
        self.apiClientProvider = { apiClient ?? GmailAPIClient.shared }
        self.syncCoordinatorProvider = { syncCoordinator ?? SyncEngine.shared }
    }

    init(
        coreDataStack: CoreDataStack = .shared,
        apiClientProvider: @escaping @MainActor @Sendable () -> GmailAPIClientProtocol,
        syncCoordinatorProvider: @escaping @MainActor @Sendable () -> BackgroundSyncMessageCoordinating = {
            SyncEngine.shared
        }
    ) {
        self.makeBackgroundContext = { coreDataStack.newBackgroundContext() }
        self.saveContext = { coreDataStack.saveIfNeeded(context: $0) }
        self.apiClientProvider = apiClientProvider
        self.syncCoordinatorProvider = syncCoordinatorProvider
    }

    init(
        makeBackgroundContext: @escaping @Sendable () -> NSManagedObjectContext,
        saveContext: @escaping @Sendable (NSManagedObjectContext) -> Bool,
        apiClient: GmailAPIClientProtocol,
        syncCoordinator: BackgroundSyncMessageCoordinating
    ) {
        self.makeBackgroundContext = makeBackgroundContext
        self.saveContext = saveContext
        self.apiClientProvider = { apiClient }
        self.syncCoordinatorProvider = { syncCoordinator }
    }

    /// Processes history changes and categorizes them
    func processHistoryChanges(
        histories: [HistoryRecord],
        in context: NSManagedObjectContext? = nil
    ) async {
        let context = context ?? makeBackgroundContext()
        let changeSet = Self.buildChangeSet(from: histories)

        if !changeSet.messageIdsToDelete.isEmpty {
            await deleteMessages(messageIds: Array(changeSet.messageIdsToDelete), in: context)
            _ = saveContext(context)
        }

        if !changeSet.messageIdsToFetch.isEmpty {
            await fetchAndStoreMessages(
                messageIds: Array(changeSet.messageIdsToFetch),
                in: context
            )
        }

        if !changeSet.messageIdsToDelete.isEmpty || !changeSet.messageIdsToFetch.isEmpty {
            let syncCoordinator = await MainActor.run { self.syncCoordinator }
            await syncCoordinator.updateConversationRollups(in: context)
            _ = saveContext(context)
        }
    }

    /// Builds fetch/delete sets from history records.
    /// Deleted messages take precedence over fetches to avoid reintroducing removed data.
    static func buildChangeSet(from histories: [HistoryRecord]) -> BackgroundHistoryChangeSet {
        var messagesToFetch: Set<String> = []
        var messagesToDelete: Set<String> = []

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
                    messagesToFetch.insert(labelAdded.message.id)
                }
            }

            if let labelsRemoved = history.labelsRemoved {
                for labelRemoved in labelsRemoved {
                    messagesToFetch.insert(labelRemoved.message.id)
                }
            }
        }

        messagesToFetch.subtract(messagesToDelete)
        return BackgroundHistoryChangeSet(
            messageIdsToFetch: messagesToFetch,
            messageIdsToDelete: messagesToDelete
        )
    }

    /// Fetches messages from the API and stores them in Core Data
    func fetchAndStoreMessages(
        messageIds: [String],
        in context: NSManagedObjectContext? = nil
    ) async {
        let ownsContext = context == nil
        let context = context ?? makeBackgroundContext()
        let syncCoordinator = await MainActor.run { self.syncCoordinator }
        let apiClient = await MainActor.run { self.apiClient }

        // Prefetch label IDs for efficient lookups (IDs are Sendable, safe to pass across async boundaries)
        let labelIds = await syncCoordinator.prefetchLabelIdsForBackground(in: context)

        let batchSize = 10
        var successCount = 0
        var failedCount = 0

        for batch in messageIds.chunked(into: batchSize) {
            await withTaskGroup(of: (String, Result<GmailMessage, Error>).self) { group in
                for messageId in batch {
                    group.addTask {
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
                        await syncCoordinator.saveMessage(message, labelIds: labelIds, in: context)
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

        if ownsContext {
            await syncCoordinator.updateConversationRollups(in: context)
            _ = saveContext(context)
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
