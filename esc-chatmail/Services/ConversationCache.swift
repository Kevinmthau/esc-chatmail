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
            size += (message.bodyTextValue?.count ?? 0) * 2
            size += 1024 // Overhead per message
        }
        return size
    }
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

    // Preloader (extracted)
    private let preloader: ConversationPreloader

    // Statistics (using shared type from CacheProtocol)
    private var stats = LRUCacheStatistics()
    private var accessTimes: [TimeInterval] = []

    // Publishers
    @Published var currentMemoryUsage = 0
    @Published var cacheItemCount = 0

    var isPreloading: Bool {
        preloader.isPreloading
    }

    private var cancellables = Set<AnyCancellable>()

    private init() {
        self.preloader = ConversationPreloader()
        preloader.setCache(self)
        setupMemoryWarningObserver()
        startPeriodicCleanup()
    }

    // MARK: - Cache Operations

    func get(_ conversationId: String) -> CachedConversation? {
        let startTime = Date()

        if let cached = cache[conversationId] {
            // Check TTL
            if Date().timeIntervalSince(cached.lastAccessed) > ttl {
                invalidate(conversationId)
                stats.recordMiss()
                return nil
            }

            // Cache hit
            cached.access()
            moveToFront(conversationId)
            stats.recordHit()

            recordAccessTime(Date().timeIntervalSince(startTime))
            return cached
        }

        // Cache miss
        stats.recordMiss()
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
        stats.currentItemCount = cache.count
    }

    func preload(_ conversationIds: [String]) {
        preloader.preload(conversationIds)
    }

    func invalidate(_ conversationId: String) {
        cache.removeValue(forKey: conversationId)
        lruOrder.removeAll { $0 == conversationId }
        updateMemoryUsage()
        cacheItemCount = cache.count
        stats.currentItemCount = cache.count
    }

    func clear() {
        cache.removeAll()
        lruOrder.removeAll()
        preloader.cancel()

        currentMemoryUsage = 0
        cacheItemCount = 0
        stats.currentItemCount = 0
    }

    // MARK: - Preloading (delegated)

    func preloadAdjacentConversations(currentId: String, in conversationIds: [String]) {
        preloader.preloadAdjacentConversations(currentId: currentId, in: conversationIds)
    }

    func warmCache(with recentConversations: [Conversation]) {
        preloader.warmCache(with: recentConversations)
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
        stats.recordEviction()

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
            stats.recordEviction()
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

    func getStatistics() -> LRUCacheStatistics {
        return stats
    }

    /// Returns detailed statistics including access time info
    func getDetailedStatistics() -> (stats: LRUCacheStatistics, avgAccessTime: TimeInterval, memoryUsage: Int) {
        let avgAccessTime = accessTimes.isEmpty ? 0 : accessTimes.reduce(0, +) / Double(accessTimes.count)
        return (stats, avgAccessTime, currentMemoryUsage)
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
