import Foundation
import CoreData
import Combine
import UIKit

// MARK: - Cached Conversation
final class CachedConversation {
    let id: String
    let conversation: Conversation
    var messages: [Message]
    var lastAccessed: Date
    var accessCount: Int
    var memorySize: Int
    var preloadedHTML: [String: String] = [:]

    init(conversation: Conversation, messages: [Message]) {
        self.id = conversation.id.uuidString
        self.conversation = conversation
        self.messages = messages
        self.lastAccessed = Date()
        self.accessCount = 0
        self.memorySize = Self.calculateMemorySize(messages: messages)
    }

    func access() {
        lastAccessed = Date()
        accessCount += 1
    }

    private static func calculateMemorySize(messages: [Message]) -> Int {
        // Estimate memory usage
        var size = 0
        for message in messages {
            size += (message.snippet?.count ?? 0) * 2 // Unicode chars
            size += ((message.value(forKey: "bodyText") as? String)?.count ?? 0) * 2
            size += 1024 // Overhead per message
        }
        return size
    }
}

// MARK: - Cache Statistics
struct CacheStatistics {
    let totalItems: Int
    let totalMemoryUsage: Int
    let hitRate: Double
    let missRate: Double
    let averageAccessTime: TimeInterval
    let evictionCount: Int
}

// MARK: - Conversation Cache
@MainActor
final class ConversationCache: ObservableObject {
    static let shared = ConversationCache()

    // Configuration
    private let maxCacheSize = 50 * 1024 * 1024 // 50MB
    private let maxCacheItems = 100
    private let ttl: TimeInterval = 300 // 5 minutes

    // Cache storage
    private var cache: [String: CachedConversation] = [:]
    private var lruOrder: [String] = []

    // Preloading
    private var preloadQueue: Set<String> = []
    private var preloadTask: Task<Void, Never>?

    // Statistics
    private var cacheHits = 0
    private var cacheMisses = 0
    private var evictions = 0
    private var accessTimes: [TimeInterval] = []

    // Publishers
    @Published var currentMemoryUsage = 0
    @Published var cacheItemCount = 0
    @Published var isPreloading = false

    private let coreDataStack = CoreDataStack.shared
    private var cancellables = Set<AnyCancellable>()

    private init() {
        setupMemoryWarningObserver()
        startPeriodicCleanup()
    }

    // MARK: - Cache Operations

    func get(_ conversationId: String) -> CachedConversation? {
        let startTime = Date()

        if let cached = cache[conversationId] {
            // Cache hit
            cached.access()
            moveToFront(conversationId)
            cacheHits += 1

            recordAccessTime(Date().timeIntervalSince(startTime))
            return cached
        }

        // Cache miss
        cacheMisses += 1
        recordAccessTime(Date().timeIntervalSince(startTime))
        return nil
    }

    func set(_ conversation: Conversation, messages: [Message]) {
        let cached = CachedConversation(conversation: conversation, messages: messages)
        let conversationId = conversation.id.uuidString

        // Check if we need to evict
        if shouldEvict(newSize: cached.memorySize) {
            evictLeastRecentlyUsed()
        }

        cache[conversationId] = cached
        moveToFront(conversationId)

        updateMemoryUsage()
        cacheItemCount = cache.count
    }

    func preload(_ conversationIds: [String]) {
        let idsToPreload = conversationIds.filter { cache[$0] == nil }
        guard !idsToPreload.isEmpty else { return }

        preloadQueue.formUnion(idsToPreload)

        if preloadTask == nil {
            startPreloading()
        }
    }

    func invalidate(_ conversationId: String) {
        cache.removeValue(forKey: conversationId)
        lruOrder.removeAll { $0 == conversationId }
        updateMemoryUsage()
        cacheItemCount = cache.count
    }

    func clear() {
        cache.removeAll()
        lruOrder.removeAll()
        preloadQueue.removeAll()
        preloadTask?.cancel()
        preloadTask = nil

        currentMemoryUsage = 0
        cacheItemCount = 0
    }

    // MARK: - Preloading

    private func startPreloading() {
        guard preloadTask == nil else { return }

        isPreloading = true

        preloadTask = Task { [weak self] in
            guard let self = self else { return }

            while !self.preloadQueue.isEmpty {
                let conversationId = self.preloadQueue.removeFirst()

                // Load from Core Data
                await self.loadConversation(conversationId)

                // Small delay between loads to avoid blocking
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            }

            await MainActor.run {
                self.isPreloading = false
                self.preloadTask = nil
            }
        }
    }

    private func loadConversation(_ conversationId: String) async {
        let context = coreDataStack.newBackgroundContext()

        await context.perform { [weak self] in
            guard let self = self else { return }

            let request = Conversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", conversationId)
            request.relationshipKeyPathsForPrefetching = ["messages", "participants"]

            guard let conversation = try? context.fetch(request).first else { return }

            let messageRequest = Message.fetchRequest()
            messageRequest.predicate = NSPredicate(format: "conversation == %@", conversation)
            messageRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Message.internalDate, ascending: true)]
            messageRequest.fetchBatchSize = 50

            guard let messages = try? context.fetch(messageRequest) else { return }

            Task { @MainActor in
                self.set(conversation, messages: messages)
            }
        }
    }

    // MARK: - LRU Management

    private func moveToFront(_ conversationId: String) {
        lruOrder.removeAll { $0 == conversationId }
        lruOrder.insert(conversationId, at: 0)
    }

    private func shouldEvict(newSize: Int) -> Bool {
        return currentMemoryUsage + newSize > maxCacheSize || cache.count >= maxCacheItems
    }

    private func evictLeastRecentlyUsed() {
        guard let lruId = lruOrder.last else { return }

        cache.removeValue(forKey: lruId)
        lruOrder.removeLast()
        evictions += 1

        updateMemoryUsage()
    }

    // MARK: - TTL Management

    private func startPeriodicCleanup() {
        Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.cleanupExpiredItems()
            }
            .store(in: &cancellables)
    }

    private func cleanupExpiredItems() {
        let now = Date()
        var expiredIds: [String] = []

        for (id, cached) in cache {
            if now.timeIntervalSince(cached.lastAccessed) > ttl {
                expiredIds.append(id)
            }
        }

        for id in expiredIds {
            invalidate(id)
        }
    }

    // MARK: - Memory Management

    private func setupMemoryWarningObserver() {
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in
                self?.handleMemoryWarning()
            }
            .store(in: &cancellables)
    }

    private func handleMemoryWarning() {
        // Aggressively clear cache on memory warning
        let itemsToKeep = min(5, cache.count / 4)

        while cache.count > itemsToKeep {
            evictLeastRecentlyUsed()
        }
    }

    private func updateMemoryUsage() {
        currentMemoryUsage = cache.values.reduce(0) { $0 + $1.memorySize }
    }

    // MARK: - Statistics

    private func recordAccessTime(_ time: TimeInterval) {
        accessTimes.append(time)
        if accessTimes.count > 100 {
            accessTimes.removeFirst()
        }
    }

    func getStatistics() -> CacheStatistics {
        let totalAccesses = cacheHits + cacheMisses
        let hitRate = totalAccesses > 0 ? Double(cacheHits) / Double(totalAccesses) : 0
        let avgAccessTime = accessTimes.isEmpty ? 0 : accessTimes.reduce(0, +) / Double(accessTimes.count)

        return CacheStatistics(
            totalItems: cache.count,
            totalMemoryUsage: currentMemoryUsage,
            hitRate: hitRate,
            missRate: 1 - hitRate,
            averageAccessTime: avgAccessTime,
            evictionCount: evictions
        )
    }

    // MARK: - Intelligent Preloading

    func preloadAdjacentConversations(currentId: String, in conversationIds: [String]) {
        guard let currentIndex = conversationIds.firstIndex(of: currentId) else { return }

        var toPreload: [String] = []

        // Preload next 2 conversations
        for i in 1...2 {
            let nextIndex = currentIndex + i
            if nextIndex < conversationIds.count {
                toPreload.append(conversationIds[nextIndex])
            }
        }

        // Preload previous conversation
        if currentIndex > 0 {
            toPreload.append(conversationIds[currentIndex - 1])
        }

        preload(toPreload)
    }

    func warmCache(with recentConversations: [Conversation]) {
        Task {
            for conversation in recentConversations.prefix(10) {
                guard cache[conversation.id.uuidString] == nil else { continue }

                await loadConversation(conversation.id.uuidString)

                // Rate limit warming
                try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
            }
        }
    }
}

// MARK: - Cache-Aware Conversation Loader
@MainActor
final class CachedConversationLoader: ObservableObject {
    @Published var messages: [Message] = []
    @Published var isLoading = false
    @Published var cacheHit = false

    private let cache = ConversationCache.shared
    private let coreDataStack = CoreDataStack.shared

    func loadConversation(_ conversationId: String) async {
        isLoading = true
        cacheHit = false

        // Try cache first
        if let cached = cache.get(conversationId) {
            self.messages = cached.messages
            self.cacheHit = true
            self.isLoading = false
            return
        }

        // Load from Core Data
        let context = coreDataStack.newBackgroundContext()
        let loadedMessages = await context.perform {
            let request = Message.fetchRequest()
            request.predicate = NSPredicate(format: "conversation.id == %@", conversationId)
            request.sortDescriptors = [NSSortDescriptor(keyPath: \Message.internalDate, ascending: true)]
            return (try? context.fetch(request)) ?? []
        }

        // Cache for future use
        if let conversation = loadedMessages.first?.conversation {
            cache.set(conversation, messages: loadedMessages)
        }

        self.messages = loadedMessages
        self.isLoading = false
    }
}