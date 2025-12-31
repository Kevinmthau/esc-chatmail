import SwiftUI
import CoreData
import Combine

// MARK: - Conversation List State
@MainActor
final class ConversationListState: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var isLoading = false
    @Published var selectedConversation: Conversation?
    @Published var preloadedIds = Set<String>()

    private let cache = ConversationCache.shared
    private let coreDataStack = CoreDataStack.shared
    private var cancellables = Set<AnyCancellable>()
    private var preloadTask: Task<Void, Never>?

    init() {
        setupObservers()
    }

    private func setupObservers() {
        // Listen for sync completion
        NotificationCenter.default.publisher(for: .syncCompleted)
            .sink { [weak self] _ in
                Task {
                    await self?.refreshConversations()
                }
            }
            .store(in: &cancellables)
    }

    func refreshConversations() async {
        isLoading = true

        let context = coreDataStack.viewContext
        let request = Conversation.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Conversation.pinned, ascending: false),
            NSSortDescriptor(keyPath: \Conversation.lastMessageDate, ascending: false)
        ]
        request.predicate = NSPredicate(format: "archivedAt == nil")
        request.fetchBatchSize = 30
        request.relationshipKeyPathsForPrefetching = ["messages", "participants", "participants.person"]

        do {
            let fetchedConversations = try context.fetch(request)
            conversations = fetchedConversations

            // Warm cache with recent conversations
            cache.warmCache(with: Array(fetchedConversations.prefix(10)))

            // Prefetch Person data for all participants to avoid N+1 queries
            let allEmails = fetchedConversations.prefix(30).flatMap { conversation -> [String] in
                guard let participants = conversation.participants else {
                    return []
                }
                return participants.compactMap { $0.person?.email }
            }
            let uniqueEmails = Array(Set(allEmails))
            await PersonCache.shared.prefetch(emails: uniqueEmails)

            // Prefetch avatars for first 20 conversations (don't block on this)
            let avatarEmails = Array(Set(fetchedConversations.prefix(20).flatMap { conversation -> [String] in
                guard let participants = conversation.participants else { return [] }
                return participants.compactMap { $0.person?.email }
            }))
            Task.detached(priority: .userInitiated) {
                await ProfilePhotoResolver.shared.prefetchPhotos(for: avatarEmails)
            }

            isLoading = false
        } catch {
            Log.error("Failed to fetch conversations", category: .coreData, error: error)
            isLoading = false
        }
    }

    func preloadAdjacentConversations(for conversation: Conversation) {
        guard let index = conversations.firstIndex(of: conversation) else { return }

        var toPreload: [String] = []

        // Preload next 3 conversations
        for i in 1...3 {
            let nextIndex = index + i
            if nextIndex < conversations.count {
                let conversationId = conversations[nextIndex].id.uuidString
                if !preloadedIds.contains(conversationId) {
                    toPreload.append(conversationId)
                    preloadedIds.insert(conversationId)
                }
            }
        }

        // Preload previous 2 conversations
        for i in 1...2 {
            let prevIndex = index - i
            if prevIndex >= 0 {
                let conversationId = conversations[prevIndex].id.uuidString
                if !preloadedIds.contains(conversationId) {
                    toPreload.append(conversationId)
                    preloadedIds.insert(conversationId)
                }
            }
        }

        if !toPreload.isEmpty {
            cache.preload(toPreload)

            // Also prefetch avatars for adjacent conversations
            let adjacentConversations = toPreload.compactMap { id in
                conversations.first { $0.id.uuidString == id }
            }
            let adjacentEmails = adjacentConversations.flatMap { conversation -> [String] in
                guard let participants = conversation.participants else { return [] }
                return participants.compactMap { $0.person?.email }
            }
            if !adjacentEmails.isEmpty {
                Task.detached(priority: .utility) {
                    await ProfilePhotoResolver.shared.prefetchPhotos(for: adjacentEmails)
                }
            }
        }
    }

    func selectConversation(_ conversation: Conversation) {
        selectedConversation = conversation
        preloadAdjacentConversations(for: conversation)
    }
}
