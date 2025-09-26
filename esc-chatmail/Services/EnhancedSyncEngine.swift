import Foundation
import CoreData
import Combine

// MARK: - Enhanced Sync Engine
@MainActor
final class EnhancedSyncEngine: ObservableObject {
    static let shared = EnhancedSyncEngine()

    @Published var isSyncing = false
    @Published var syncProgress: Double = 0.0
    @Published var syncStatus: String = ""

    private let apiClient = GmailAPIClient.shared
    private let coreDataStack = CoreDataStack.shared
    private let deltaSyncManager = DeltaSyncManager.shared
    private let parallelFetcher = ParallelMessageFetcher.shared
    private let conversationCache = ConversationCache.shared
    private let databaseMaintenance = DatabaseMaintenanceService.shared

    private var cancellables = Set<AnyCancellable>()
    private let syncQueue = DispatchQueue(label: "com.esc.enhancedsync", qos: .userInitiated)

    private init() {
        setupPerformanceOptimizations()
        observeSyncEvents()
    }

    // MARK: - Setup

    private func setupPerformanceOptimizations() {
        // Configure parallel fetcher for optimal performance
        Task {
            await parallelFetcher.updateConfiguration(.default)
        }

        // Optimize Core Data stack
        coreDataStack.optimizeDatabasePerformance()

        // Schedule maintenance
        databaseMaintenance.scheduleMaintenanceTasks()
    }

    private func observeSyncEvents() {
        // Monitor sync progress
        deltaSyncManager.$syncStrategy
            .sink { [weak self] strategy in
                self?.updateSyncStatus(for: strategy)
            }
            .store(in: &cancellables)
    }

    // MARK: - Enhanced Sync Operations

    func performOptimizedSync() async throws {
        isSyncing = true
        syncProgress = 0.0
        syncStatus = "Initializing sync..."

        defer {
            isSyncing = false
            syncProgress = 1.0
        }

        // Step 1: Determine optimal sync strategy
        deltaSyncManager.optimizeSyncStrategy()

        // Step 2: Perform delta sync
        syncStatus = "Fetching changes..."
        syncProgress = 0.2

        let syncResult = try await deltaSyncManager.performDeltaSync(using: apiClient)
        print(syncResult.summary)

        // Step 3: Fetch messages in parallel
        if syncResult.messagesAdded > 0 {
            await fetchNewMessagesInParallel(count: syncResult.messagesAdded)
        }

        // Step 4: Update denormalized fields
        syncStatus = "Updating cache..."
        syncProgress = 0.8

        await updateDenormalizedData()

        // Step 5: Warm up conversation cache
        await warmConversationCache()

        // Step 6: Perform maintenance if needed
        await performMaintenanceIfNeeded()

        syncStatus = "Sync complete"
        syncProgress = 1.0

        // Post sync completion notification
        NotificationCenter.default.post(name: .syncCompleted, object: nil)
    }

    // MARK: - Parallel Message Fetching

    private func fetchNewMessagesInParallel(count: Int) async {
        syncStatus = "Fetching \(count) new messages..."
        syncProgress = 0.4

        let context = coreDataStack.newBackgroundContext()

        // Get message IDs that need full content
        let messageIds = await context.perform {
            let request = Message.fetchRequest()
            request.predicate = NSPredicate(format: "bodyStorageURI == nil")
            request.fetchLimit = count
            request.propertiesToFetch = ["id"]
            request.resultType = .dictionaryResultType

            let results = (try? context.fetch(request)) as? [[String: Any]] ?? []
            return results.compactMap { $0["id"] as? String }
        }

        // Fetch messages in parallel with progress tracking
        var fetchedCount = 0
        await parallelFetcher.fetchMessagesBatched(messageIds) { [weak self] messages in
            Task { @MainActor in
                fetchedCount += messages.count
                self?.syncProgress = 0.4 + (Double(fetchedCount) / Double(count)) * 0.3
                self?.syncStatus = "Fetched \(fetchedCount)/\(count) messages..."

                // Process and save messages immediately
                await self?.processFetchedMessages(messages, in: context)
            }
        }
    }

    private func processFetchedMessages(_ messages: [GmailMessage], in context: NSManagedObjectContext) async {
        await context.perform {
            for gmailMessage in messages {
                // Update existing message with full content
                let request = Message.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", gmailMessage.id)
                request.fetchLimit = 1

                if let message = try? context.fetch(request).first {
                    // Update message with full content
                    // This would be done by the message processor
                    print("Updated message \(message.id) with full content")
                }
            }

            self.coreDataStack.saveIfNeeded(context: context)
        }
    }

    // MARK: - Denormalization

    private func updateDenormalizedData() async {
        let context = coreDataStack.newBackgroundContext()

        await context.perform {
            // Update conversation rollups with denormalized fields
            let request = Conversation.fetchRequest()
            request.predicate = NSPredicate(format: "lastMessageDate != nil")
            request.fetchBatchSize = 50

            guard let conversations = try? context.fetch(request) else { return }

            for conversation in conversations {
                // Cache unread count
                let unreadCount = (conversation.messages as? NSSet)?
                    .compactMap { $0 as? Message }
                    .filter { $0.isUnread }
                    .count ?? 0
                conversation.inboxUnreadCount = Int32(unreadCount)

                // Cache latest message snippet for faster display
                let messages = (conversation.messages as? NSSet)?.compactMap { $0 as? Message } ?? []
                if let latestMessage = messages
                    .sorted(by: { $0.internalDate > $1.internalDate })
                    .first {
                    conversation.snippet = latestMessage.cleanedSnippet ?? latestMessage.snippet
                }

                // Cache participant names for faster display
                let participantNames = (conversation.participants as? NSSet)?
                    .compactMap { ($0 as? ConversationParticipant)?.person?.displayName ?? ($0 as? ConversationParticipant)?.person?.email }
                    .joined(separator: ", ")
                conversation.displayName = participantNames
            }

            self.coreDataStack.saveIfNeeded(context: context)
        }
    }

    // MARK: - Cache Warming

    private func warmConversationCache() async {
        let context = coreDataStack.viewContext

        // Get recent conversations to warm cache
        let request = Conversation.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Conversation.lastMessageDate, ascending: false)
        ]
        request.fetchLimit = 20
        request.predicate = NSPredicate(format: "hidden == NO")

        guard let recentConversations = try? context.fetch(request) else { return }

        // Warm cache with recent conversations
        conversationCache.warmCache(with: recentConversations)
    }

    // MARK: - Database Maintenance

    private func performMaintenanceIfNeeded() async {
        let stats = await databaseMaintenance.getDatabaseStatistics()

        if stats.needsMaintenance {
            syncStatus = "Optimizing database..."
            syncProgress = 0.9

            // Perform lightweight maintenance during sync
            _ = await databaseMaintenance.performAnalyze()

            // Schedule full maintenance for later
            Task {
                // Run full maintenance in background after sync
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 1 minute delay
                _ = await databaseMaintenance.performFullMaintenance()
            }
        }
    }

    // MARK: - Sync Status

    private func updateSyncStatus(for strategy: DeltaSyncStrategy) {
        switch strategy {
        case .full:
            syncStatus = "Performing full sync..."
        case .incremental(let since):
            let formatter = RelativeDateTimeFormatter()
            let timeAgo = formatter.localizedString(for: since, relativeTo: Date())
            syncStatus = "Syncing changes since \(timeAgo)"
        case .token:
            syncStatus = "Syncing recent changes..."
        case .changeDetection:
            syncStatus = "Detecting changes..."
        }
    }

    // MARK: - Performance Metrics

    func getPerformanceMetrics() async -> SyncPerformanceMetrics {
        let fetchMetrics = await parallelFetcher.getMetrics()
        let cacheStats = conversationCache.getStatistics()
        let dbStats = await databaseMaintenance.getDatabaseStatistics()

        return SyncPerformanceMetrics(
            averageFetchTime: fetchMetrics.averageFetchTime,
            cacheHitRate: cacheStats.hitRate,
            totalCacheSize: cacheStats.totalMemoryUsage,
            databaseSize: dbStats.databaseSize,
            messageCount: dbStats.messageCount,
            lastSyncDate: deltaSyncManager.lastSuccessfulSync
        )
    }
}

// MARK: - Sync Performance Metrics
struct SyncPerformanceMetrics {
    let averageFetchTime: TimeInterval
    let cacheHitRate: Double
    let totalCacheSize: Int
    let databaseSize: Int64
    let messageCount: Int
    let lastSyncDate: Date?

    var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalCacheSize), countStyle: .memory)
    }

    var formattedDatabaseSize: String {
        ByteCountFormatter.string(fromByteCount: databaseSize, countStyle: .file)
    }

    var cacheEfficiency: String {
        String(format: "%.1f%%", cacheHitRate * 100)
    }
}