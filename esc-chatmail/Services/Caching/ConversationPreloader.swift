import Foundation
import CoreData

/// Handles background preloading of conversations for the cache.
/// Separated from ConversationCache to improve code organization.
@MainActor
final class ConversationPreloader {
    private var preloadQueue: Set<String> = []
    private var preloadTask: Task<Void, Never>?
    private let coreDataStack: CoreDataStack
    private weak var cache: ConversationCache?

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

        if preloadTask == nil {
            startPreloading()
        }
    }

    func cancel() {
        preloadTask?.cancel()
        preloadTask = nil
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

        preloadTask = Task { [weak self] in
            guard let self = self else { return }

            while !self.preloadQueue.isEmpty {
                let conversationId = self.preloadQueue.removeFirst()

                // Load from Core Data
                await self.loadConversation(conversationId)

                // Small delay between loads to avoid blocking
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            }

            self.preloadTask = nil
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
                self.cache?.set(conversation, messages: messages)
            }
        }
    }
}
