import Foundation
import CoreData
import Combine

// MARK: - Sync Priority
enum SyncPriority {
    case userInitiated
    case background
    case utility

    var qos: DispatchQoS {
        switch self {
        case .userInitiated: return .userInitiated
        case .background: return .background
        case .utility: return .utility
        }
    }
}

// MARK: - Sync Operation
struct SyncOperation {
    let id: UUID = UUID()
    let type: SyncType
    let priority: SyncPriority
    let createdAt: Date = Date()

    enum SyncType {
        case initial
        case incremental
        case conversation(String)
        case message(String)
    }
}

// MARK: - Sync Queue Actor
actor SyncQueueActor {
    private var operationQueue: [SyncOperation] = []
    private var currentOperation: SyncOperation?
    private var isProcessing = false

    func enqueue(_ operation: SyncOperation) {
        // Insert based on priority
        let insertIndex = operationQueue.firstIndex {
            switch (operation.priority, $0.priority) {
            case (.userInitiated, .userInitiated), (.background, .background), (.utility, .utility):
                return false
            case (.userInitiated, _):
                return false
            case (_, .userInitiated):
                return true
            case (.utility, .background):
                return true
            default:
                return false
            }
        } ?? operationQueue.count
        operationQueue.insert(operation, at: insertIndex)
    }

    func dequeue() -> SyncOperation? {
        guard !operationQueue.isEmpty else { return nil }
        currentOperation = operationQueue.removeFirst()
        return currentOperation
    }

    func setProcessing(_ processing: Bool) {
        isProcessing = processing
    }

    func isCurrentlyProcessing() -> Bool {
        return isProcessing
    }

    func clearQueue() {
        operationQueue.removeAll()
        currentOperation = nil
        isProcessing = false
    }

    func queueCount() -> Int {
        return operationQueue.count
    }
}

// MARK: - Optimized Sync Engine
@MainActor
final class SyncEngineOptimized: ObservableObject {
    static let shared = SyncEngineOptimized()

    // Published properties for UI updates
    @Published var isSyncing = false
    @Published var syncProgress: Double = 0.0
    @Published var syncStatus: String = ""
    @Published var pendingOperations: Int = 0

    // Dependencies
    private let apiClient = GmailAPIClient.shared
    private let coreDataStack = CoreDataStack.shared
    private let batchOperations = CoreDataBatchOperations()
    private let messageProcessor = MessageProcessor()
    private let conversationManager = ConversationManager()

    // Sync management
    private let syncQueue = SyncQueueActor()
    private var syncTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // Configuration
    private let maxConcurrentFetches = 5
    private let messageBatchSize = 100
    private let saveInterval = 500

    private init() {
        startSyncProcessor()
    }

    deinit {
        syncTask?.cancel()
        cancellables.forEach { $0.cancel() }
    }

    // MARK: - Public Methods

    func performInitialSync(priority: SyncPriority = .userInitiated) async {
        let operation = SyncOperation(type: .initial, priority: priority)
        await syncQueue.enqueue(operation)
        await updatePendingOperations()
    }

    func performIncrementalSync(priority: SyncPriority = .utility) async {
        let operation = SyncOperation(type: .incremental, priority: priority)
        await syncQueue.enqueue(operation)
        await updatePendingOperations()
    }

    func syncConversation(_ conversationId: String, priority: SyncPriority = .userInitiated) async {
        let operation = SyncOperation(type: .conversation(conversationId), priority: priority)
        await syncQueue.enqueue(operation)
        await updatePendingOperations()
    }

    func cancelAllSyncs() async {
        await syncQueue.clearQueue()
        syncTask?.cancel()
        await MainActor.run {
            self.isSyncing = false
            self.syncProgress = 0.0
            self.syncStatus = "Sync cancelled"
            self.pendingOperations = 0
        }
    }

    // MARK: - Private Methods

    private func startSyncProcessor() {
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }

                // Get next operation from queue
                if let operation = await self.syncQueue.dequeue() {
                    await self.syncQueue.setProcessing(true)
                    await self.updatePendingOperations()

                    // Process operation based on type
                    switch operation.type {
                    case .initial:
                        await self.executeInitialSync()
                    case .incremental:
                        await self.executeIncrementalSync()
                    case .conversation(let id):
                        await self.syncSingleConversation(id)
                    case .message(let id):
                        await self.syncSingleMessage(id)
                    }

                    await self.syncQueue.setProcessing(false)
                    await self.updatePendingOperations()
                }

                // Sleep briefly when queue is empty
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }
        }
    }

    private func updatePendingOperations() async {
        let count = await syncQueue.queueCount()
        await MainActor.run {
            self.pendingOperations = count
        }
    }

    private func executeInitialSync() async {
        await MainActor.run {
            self.isSyncing = true
            self.syncProgress = 0.0
            self.syncStatus = "Starting full sync..."
        }

        do {
            // Create dedicated background context for sync
            let syncContext = coreDataStack.newBackgroundContext()
            syncContext.undoManager = nil
            syncContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

            // Phase 1: Fetch profile and aliases
            await updateProgress(0.1, status: "Fetching account info...")
            _ = try await apiClient.getProfile()
            let sendAsList = try await apiClient.listSendAs()
            _ = sendAsList
                .filter { $0.treatAsAlias == true || $0.isPrimary == true }
                .map { $0.sendAsEmail }

            // Phase 2: Fetch labels
            await updateProgress(0.15, status: "Fetching labels...")
            _ = try await apiClient.listLabels()

            // Phase 3: Fetch message list
            await updateProgress(0.2, status: "Fetching message list...")
            let messageIds = try await fetchAllMessageIds()

            // Phase 4: Batch fetch and process messages
            await updateProgress(0.3, status: "Processing \(messageIds.count) messages...")
            let messages = try await batchFetchMessages(messageIds, context: syncContext)

            // Phase 5: Batch insert messages
            await updateProgress(0.7, status: "Saving messages...")
            try await batchOperations.batchInsertMessages(
                messages,
                configuration: BatchConfiguration.heavy
            )

            // Phase 6: Update conversations
            await updateProgress(0.85, status: "Updating conversations...")
            await updateConversationsInBackground(context: syncContext)

            // Phase 7: Save and merge
            await updateProgress(0.95, status: "Finalizing...")
            try await saveAndMergeContext(syncContext)

            await updateProgress(1.0, status: "Sync complete")
            await MainActor.run {
                self.isSyncing = false
                NotificationCenter.default.post(name: .syncCompleted, object: nil)
            }

        } catch {
            await handleSyncError(error)
        }
    }

    private func executeIncrementalSync() async {
        await MainActor.run {
            self.isSyncing = true
            self.syncStatus = "Checking for updates..."
        }

        do {
            // Get last history ID
            guard let historyId = await getLastHistoryId() else {
                // No history ID, perform initial sync instead
                await executeInitialSync()
                return
            }

            // Create background context
            let syncContext = coreDataStack.newBackgroundContext()
            syncContext.undoManager = nil

            // Fetch history changes
            let historyRecords = try await fetchHistoryRecords(from: historyId)

            if !historyRecords.isEmpty {
                await updateStatus("Processing \(historyRecords.count) updates...")

                // Process history records in batches
                let updates = processHistoryRecords(historyRecords)

                // Apply updates using batch operations
                if !updates.newMessages.isEmpty {
                    try await batchOperations.batchInsertMessages(
                        updates.newMessages,
                        configuration: BatchConfiguration.lightweight
                    )
                }

                if !updates.messageUpdates.isEmpty {
                    try await batchOperations.batchUpdateMessages(
                        with: updates.messageUpdates,
                        configuration: BatchConfiguration.lightweight
                    )
                }

                if !updates.deletedMessageIds.isEmpty {
                    try await batchOperations.batchDeleteMessages(
                        withIds: updates.deletedMessageIds,
                        configuration: BatchConfiguration.lightweight
                    )
                }

                // Update conversations
                await updateConversationsInBackground(context: syncContext)

                // Save and merge
                try await saveAndMergeContext(syncContext)
            }

            await MainActor.run {
                self.isSyncing = false
                self.syncStatus = "Sync complete"
                NotificationCenter.default.post(name: .syncCompleted, object: nil)
            }

        } catch {
            await handleSyncError(error)
        }
    }

    private func batchFetchMessages(_ ids: [String], context: NSManagedObjectContext) async throws -> [ProcessedMessage] {
        var allMessages: [ProcessedMessage] = []
        let semaphore = AsyncSemaphore(value: maxConcurrentFetches)
        let processor = MessageProcessor() // Create local instance to avoid actor isolation

        // Process in parallel with concurrency limit
        await withTaskGroup(of: ProcessedMessage?.self) { group in
            for batch in ids.chunked(into: messageBatchSize) {
                for id in batch {
                    group.addTask { [weak self] in
                        await semaphore.wait()
                        defer { Task { await semaphore.signal() } }

                        guard let self = self else { return nil }

                        do {
                            let gmailMessage = try await self.apiClient.getMessage(id: id)
                            return processor.processGmailMessage(
                                gmailMessage,
                                myAliases: Set(),
                                in: context
                            )
                        } catch {
                            print("Failed to fetch message \(id): \(error)")
                            return nil
                        }
                    }
                }

                // Collect results from this batch
                for await message in group {
                    if let message = message {
                        allMessages.append(message)
                    }
                }

                // Update progress
                let progress = 0.3 + (Double(allMessages.count) / Double(ids.count)) * 0.4
                await updateProgress(progress, status: "Fetched \(allMessages.count)/\(ids.count) messages")
            }
        }

        return allMessages
    }

    private func updateConversationsInBackground(context: NSManagedObjectContext) async {
        await context.perform {
            // This would contain the conversation grouping logic
            // Implemented in a background-safe manner
            print("Updating conversations in background context")
        }
    }

    private func saveAndMergeContext(_ context: NSManagedObjectContext) async throws {
        try await context.perform {
            guard context.hasChanges else { return }
            try context.save()
        }

        // Merge changes to view context
        await MainActor.run {
            self.coreDataStack.viewContext.refreshAllObjects()
        }
    }

    // MARK: - Helper Methods

    private func fetchAllMessageIds() async throws -> [String] {
        var allIds: [String] = []
        var pageToken: String?

        let installationTimestamp = KeychainService.shared.getOrCreateInstallationTimestamp()
        let epochSeconds = Int(installationTimestamp.timeIntervalSince1970)
        let query = "after:\(epochSeconds) -label:spam -label:drafts"

        repeat {
            let response = try await apiClient.listMessages(
                pageToken: pageToken,
                maxResults: 500,
                query: query
            )

            if let messages = response.messages {
                allIds.append(contentsOf: messages.map { $0.id })
            }

            pageToken = response.nextPageToken
        } while pageToken != nil

        return allIds
    }

    private func fetchHistoryRecords(from historyId: String) async throws -> [HistoryRecord] {
        var allRecords: [HistoryRecord] = []
        var pageToken: String?

        repeat {
            let response = try await apiClient.listHistory(
                startHistoryId: historyId,
                pageToken: pageToken
            )

            if let history = response.history {
                allRecords.append(contentsOf: history)
            }

            pageToken = response.nextPageToken
        } while pageToken != nil

        return allRecords
    }

    private func processHistoryRecords(_ records: [HistoryRecord]) -> (
        newMessages: [ProcessedMessage],
        messageUpdates: [(id: String, changes: [String: Any])],
        deletedMessageIds: [String]
    ) {
        // Process history records and categorize changes
        let newMessages: [ProcessedMessage] = []
        let updates: [(id: String, changes: [String: Any])] = []
        let deletions: [String] = []

        // Implementation would process each history record
        // and categorize the changes appropriately

        return (newMessages, updates, deletions)
    }

    private func getLastHistoryId() async -> String? {
        // Fetch from Core Data or Keychain
        return nil // Placeholder
    }

    private func syncSingleConversation(_ id: String) async {
        // Implement single conversation sync
        print("Syncing conversation: \(id)")
    }

    private func syncSingleMessage(_ id: String) async {
        // Implement single message sync
        print("Syncing message: \(id)")
    }

    private func updateProgress(_ progress: Double, status: String) async {
        await MainActor.run {
            self.syncProgress = progress
            self.syncStatus = status
        }
    }

    private func updateStatus(_ status: String) async {
        await MainActor.run {
            self.syncStatus = status
        }
    }

    private func handleSyncError(_ error: Error) async {
        await MainActor.run {
            self.isSyncing = false
            self.syncStatus = "Sync failed: \(error.localizedDescription)"
            print("Sync error: \(error)")
        }
    }
}

// MARK: - Async Semaphore
actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.value = value
    }

    func wait() async {
        if value > 0 {
            value -= 1
        } else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            value += 1
        }
    }
}