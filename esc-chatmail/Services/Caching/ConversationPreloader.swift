import Foundation
import CoreData

/// Handles background preloading of conversations for the cache.
/// Separated from ConversationCache to improve code organization.
@MainActor
final class ConversationPreloader {
    private var preloadQueue: Set<String> = []
    private var preloadTask: Task<Void, Never>?
    private var preloadTaskId: UUID?
    private let coreDataStack: CoreDataStack
    private weak var cache: ConversationCache?

    /// Maximum queue size to prevent unbounded growth during rapid scrolling
    private let maxQueueSize = 100

    var isPreloading: Bool {
        preloadTask != nil
    }

    init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    func setCache(_ cache: ConversationCache) {
        self.cache = cache
    }

    // MARK: - Preloading

    func preload(_ conversationIds: [String]) {
        guard let cache = cache else { return }

        let idsToPreload = conversationIds.filter { cache.get($0) == nil }
        guard !idsToPreload.isEmpty else { return }

        preloadQueue.formUnion(idsToPreload)

        // Prevent unbounded queue growth during rapid scrolling
        // Drop excess items when queue exceeds limit (older items are less relevant)
        if preloadQueue.count > maxQueueSize {
            let excess = preloadQueue.count - maxQueueSize
            for _ in 0..<excess {
                preloadQueue.remove(preloadQueue.first!)
            }
        }

        if preloadTask == nil {
            startPreloading()
        }
    }

    func cancel() {
        preloadTask?.cancel()
        preloadTask = nil
        preloadTaskId = nil
        preloadQueue.removeAll()
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
                guard let cache = cache, cache.get(conversation.id.uuidString) == nil else { continue }

                await loadConversation(conversation.id.uuidString)

                // Rate limit warming
                try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
            }
        }
    }

    // MARK: - Private

    private func startPreloading() {
        guard preloadTask == nil else { return }

        let taskId = UUID()
        preloadTaskId = taskId

        preloadTask = Task { [weak self, taskId] in
            guard let self = self else { return }

            while !self.preloadQueue.isEmpty {
                let conversationId = self.preloadQueue.removeFirst()

                // Load from Core Data
                await self.loadConversation(conversationId)

                // Small delay between loads to avoid blocking
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            }

            // Only clear task reference if this is still the active task
            // (prevents cancelled tasks from clearing a newer task's reference)
            self.clearTaskIfMatches(taskId)
        }
    }

    /// Clears the preload task reference only if it matches the given task ID
    private func clearTaskIfMatches(_ taskId: UUID) {
        if preloadTaskId == taskId {
            preloadTask = nil
            preloadTaskId = nil
        }
    }

    private func loadConversation(_ conversationId: String) async {
        let context = coreDataStack.newBackgroundContext()

        // Capture ObjectIDs from the background context, then re-fetch on MainActor
        // This prevents passing NSManagedObjects across context boundaries
        let objectIds: (conversationId: NSManagedObjectID, messageIds: [NSManagedObjectID])? = await context.perform {
            let request = Conversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", conversationId)
            request.relationshipKeyPathsForPrefetching = ["messages", "participants"]

            let conversation: Conversation?
            do {
                conversation = try context.fetch(request).first
            } catch {
                Log.error("Failed to fetch conversation for preloading", category: .coreData, error: error)
                return nil
            }
            guard let conversation = conversation else { return nil }

            let messageRequest = Message.fetchRequest()
            messageRequest.predicate = NSPredicate(format: "conversation == %@", conversation)
            messageRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Message.internalDate, ascending: true)]
            messageRequest.fetchBatchSize = 50

            let messages: [Message]
            do {
                messages = try context.fetch(messageRequest)
            } catch {
                Log.error("Failed to fetch messages for conversation preloading", category: .coreData, error: error)
                return nil
            }

            return (conversation.objectID, messages.map { $0.objectID })
        }

        guard let objectIds = objectIds else { return }

        // Re-fetch objects on MainActor using viewContext to ensure thread safety
        let viewContext = coreDataStack.viewContext
        guard let conv = try? viewContext.existingObject(with: objectIds.conversationId) as? Conversation else { return }
        let msgs = objectIds.messageIds.compactMap { try? viewContext.existingObject(with: $0) as? Message }
        cache?.set(conv, messages: msgs)
    }
}
