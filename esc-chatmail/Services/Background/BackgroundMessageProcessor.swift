import Foundation
import CoreData

protocol BackgroundSyncMessageCoordinating: AnyObject, Sendable {
    func prefetchLabelIdsForBackground(in context: NSManagedObjectContext) async -> Set<String>
    func saveMessage(
        _ gmailMessage: GmailMessage,
        labelIds: Set<String>?,
        modificationTransaction: ModificationTracker.Transaction,
        in context: NSManagedObjectContext
    ) async
    func updateConversationRollups(
        conversationIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext
    ) async
}

extension SyncEngine: BackgroundSyncMessageCoordinating {}

/// Categorized history changes for background sync processing.
struct BackgroundHistoryChangeSet {
    let messageIdsToFetch: Set<String>
    let messageIdsToDelete: Set<String>
}

struct BackgroundMessageProcessingResult: Equatable {
    let fetchedCount: Int
    let failedFetchCount: Int

    static let empty = BackgroundMessageProcessingResult(fetchedCount: 0, failedFetchCount: 0)

    var hadFetchFailures: Bool {
        failedFetchCount > 0
    }
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
    ) async -> BackgroundMessageProcessingResult {
        let context = context ?? makeBackgroundContext()
        let changeSet = Self.buildChangeSet(from: histories)
        var fetchResult = BackgroundMessageProcessingResult.empty
        let modificationTransaction = await ModificationTracker.shared.beginTransaction()
        let syncCoordinator = await MainActor.run { self.syncCoordinator }

        if !changeSet.messageIdsToDelete.isEmpty {
            let deletedConversationIDs = await deleteMessages(
                messageIds: Array(changeSet.messageIdsToDelete),
                modificationTransaction: modificationTransaction,
                in: context
            )
            if !deletedConversationIDs.isEmpty {
                await syncCoordinator.updateConversationRollups(
                    conversationIDs: deletedConversationIDs,
                    in: context
                )
            }
            guard saveContext(context) else {
                Log.error("Background history processing failed to save deletions", category: .background)
                await ModificationTracker.shared.rollbackTransaction(modificationTransaction)
                return BackgroundMessageProcessingResult(
                    fetchedCount: 0,
                    failedFetchCount: 1
                )
            }
        }

        if !changeSet.messageIdsToFetch.isEmpty {
            fetchResult = await fetchAndStoreMessages(
                messageIds: Array(changeSet.messageIdsToFetch),
                modificationTransaction: modificationTransaction,
                in: context
            )
        }

        if !changeSet.messageIdsToDelete.isEmpty || !changeSet.messageIdsToFetch.isEmpty {
            guard saveContext(context) else {
                Log.error("Background history processing failed to save before rollups", category: .background)
                await ModificationTracker.shared.rollbackTransaction(modificationTransaction)
                return BackgroundMessageProcessingResult(
                    fetchedCount: fetchResult.fetchedCount,
                    failedFetchCount: max(fetchResult.failedFetchCount, 1)
                )
            }

            let modifiedConversationIDs = await ModificationTracker.shared.commitTransaction(modificationTransaction)
            await syncCoordinator.updateConversationRollups(
                conversationIDs: modifiedConversationIDs,
                in: context
            )
            if saveContext(context) {
                await ModificationTracker.shared.consumeCommittedTransaction(modificationTransaction)
            } else {
                Log.error("Background history processing failed to save rollup updates", category: .background)
                return BackgroundMessageProcessingResult(
                    fetchedCount: fetchResult.fetchedCount,
                    failedFetchCount: max(fetchResult.failedFetchCount, 1)
                )
            }
        }

        return fetchResult
    }

    /// Builds fetch/delete sets from history records.
    /// Deleted messages take precedence over fetches to avoid reintroducing removed data.
    static func buildChangeSet(from histories: [HistoryRecord]) -> BackgroundHistoryChangeSet {
        var messagesToFetch: Set<String> = []
        var messagesToDelete: Set<String> = []

        for history in histories {
            if let messagesAdded = history.messagesAdded {
                for messageAdded in messagesAdded {
                    if let labelIds = messageAdded.message.labelIds,
                       let excludedMailboxLabel = labelIds.first(where: MessagePersister.excludedMailboxLabelIDs.contains) {
                        Log.debug(
                            "Skipping \(excludedMailboxLabel.lowercased()) message from history: \(messageAdded.message.id)",
                            category: .background
                        )
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
        modificationTransaction: ModificationTracker.Transaction? = nil,
        in context: NSManagedObjectContext? = nil
    ) async -> BackgroundMessageProcessingResult {
        let ownsContext = context == nil
        let context = context ?? makeBackgroundContext()
        let syncCoordinator = await MainActor.run { self.syncCoordinator }
        let apiClient = await MainActor.run { self.apiClient }
        let ownedTransaction = ownsContext ? await ModificationTracker.shared.beginTransaction() : nil
        guard let transaction = modificationTransaction ?? ownedTransaction else {
            Log.error("Background message fetch started without a modification transaction", category: .background)
            return .empty
        }

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
                        await syncCoordinator.saveMessage(
                            message,
                            labelIds: labelIds,
                            modificationTransaction: transaction,
                            in: context
                        )
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
            guard saveContext(context) else {
                if let ownedTransaction {
                    Log.error("Background message fetch failed to save before rollups", category: .background)
                    await ModificationTracker.shared.rollbackTransaction(ownedTransaction)
                }
                return BackgroundMessageProcessingResult(
                    fetchedCount: successCount,
                    failedFetchCount: max(failedCount, 1)
                )
            }

            let modifiedConversationIDs = await ModificationTracker.shared.commitTransaction(ownedTransaction!)
            await syncCoordinator.updateConversationRollups(
                conversationIDs: modifiedConversationIDs,
                in: context
            )
            if saveContext(context) {
                await ModificationTracker.shared.consumeCommittedTransaction(ownedTransaction!)
            } else {
                Log.error("Background message fetch failed to save rollup updates", category: .background)
                return BackgroundMessageProcessingResult(
                    fetchedCount: successCount,
                    failedFetchCount: max(failedCount, 1)
                )
            }
        }

        return BackgroundMessageProcessingResult(
            fetchedCount: successCount,
            failedFetchCount: failedCount
        )
    }

    /// Deletes messages from Core Data
    @discardableResult
    func deleteMessages(
        messageIds: [String],
        modificationTransaction: ModificationTracker.Transaction,
        in context: NSManagedObjectContext
    ) async -> Set<NSManagedObjectID> {
        let modifiedConversationIDs: Set<NSManagedObjectID> = await context.perform {
            let fetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
            fetchRequest.predicate = MessagePredicates.ids(messageIds)
            fetchRequest.fetchBatchSize = 100
            fetchRequest.relationshipKeyPathsForPrefetching = ["conversation", "attachments"]

            do {
                let messages = try context.fetch(fetchRequest)
                var conversationIDs: Set<NSManagedObjectID> = []
                conversationIDs.reserveCapacity(messages.count)

                for message in messages {
                    if let conversationID = message.conversation?.objectID {
                        conversationIDs.insert(conversationID)
                    }
                    context.delete(message)
                }

                return conversationIDs
            } catch {
                Log.error("Failed to batch delete background messages", category: .background, error: error)
                return []
            }
        }

        if !modifiedConversationIDs.isEmpty {
            await ModificationTracker.shared.trackModifiedConversations(
                modifiedConversationIDs,
                in: modificationTransaction
            )
        }

        return modifiedConversationIDs
    }
}
