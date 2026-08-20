import Foundation
import CoreData

struct ConversationWindowProvider {
    let initialLimit: Int
    let pageSize: Int
    let preloadThreshold: Int
    let contactFilterCandidateMultiplier: Int

    init(configuration: ConversationListWindowConfiguration = .default) {
        self.initialLimit = configuration.initialLimit
        self.pageSize = configuration.pageSize
        self.preloadThreshold = configuration.preloadThreshold
        self.contactFilterCandidateMultiplier = configuration.contactFilterCandidateMultiplier
    }

    func fetchWindow(
        in context: NSManagedObjectContext,
        limit: Int,
        searchText: String,
        filter: ConversationFilter,
        canMatchCurrentFilter: Bool = true,
        matchesVisibility: (Conversation) -> Bool
    ) -> [Conversation] {
        guard limit > 0 else { return [] }
        guard canMatchCurrentFilter else { return [] }

        let request = NSFetchRequest<Conversation>(entityName: "Conversation")
        // SQL mirror of ConversationListItem.SortKey's `<` — the CANONICAL
        // chat-list order. SQLite cannot call the Swift comparator, so these
        // descriptors must stay in exact agreement with it: pinned desc,
        // lastMessageDate desc (nil/NULL last on both sides), conversation
        // UUID asc.
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Conversation.pinned, ascending: false),
            NSSortDescriptor(keyPath: \Conversation.lastMessageDate, ascending: false),
            NSSortDescriptor(keyPath: \Conversation.id, ascending: true)
        ]
        request.predicate = predicate(searchText: searchText, filter: filter)
        request.fetchBatchSize = min(pageSize, max(limit, 1))
        request.relationshipKeyPathsForPrefetching = ["participants", "participants.person"]
        request.includesPendingChanges = true

        let hasSearchText = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let shouldFetchPastInvisibleCandidates: Bool
        switch filter {
        case .all, .unread:
            shouldFetchPastInvisibleCandidates = hasSearchText
        case .contacts, .other:
            shouldFetchPastInvisibleCandidates = true
        }

        do {
            if shouldFetchPastInvisibleCandidates {
                return try fetchFilteredWindow(
                    request: request,
                    in: context,
                    limit: limit,
                    matchesVisibility: matchesVisibility
                )
            }

            request.fetchLimit = limit
            let candidates = try context.fetch(request)
            return Array(candidates.lazy.filter(matchesVisibility).prefix(limit))
        } catch {
            Log.error("Failed to fetch conversation window", category: .conversation, error: error)
            return []
        }
    }

    private func fetchFilteredWindow(
        request: NSFetchRequest<Conversation>,
        in context: NSManagedObjectContext,
        limit: Int,
        matchesVisibility: (Conversation) -> Bool
    ) throws -> [Conversation] {
        let pendingObjects = context.insertedObjects
            .union(context.updatedObjects)
            .union(context.deletedObjects)
        let pendingConversations = pendingObjects.compactMap { $0 as? Conversation }
        let pendingIDs = Set(pendingConversations.map(\.objectID))
        let pendingVisibleConversations = pendingConversations
            .filter { conversation in
                !conversation.isDeleted &&
                    conversation.archivedAt == nil &&
                    matchesVisibility(conversation)
            }
            .sorted(by: sortsBefore(_:_:))
            .prefix(limit)

        // Core Data reapplies pending inserts and updates to every offset page
        // when includesPendingChanges is true. Page only persisted rows, then
        // merge the context's pending conversations once below.
        request.includesPendingChanges = false

        var persistedVisibleConversations: [Conversation] = []
        var persistedVisibleIDs = Set<NSManagedObjectID>()
        var fetchOffset = 0
        let candidateBatchSize = max(limit * contactFilterCandidateMultiplier, limit, pageSize)

        while persistedVisibleConversations.count < limit {
            request.fetchOffset = fetchOffset
            request.fetchLimit = candidateBatchSize

            let candidates = try context.fetch(request)
            guard !candidates.isEmpty else { break }

            for conversation in candidates {
                guard !pendingIDs.contains(conversation.objectID),
                      persistedVisibleIDs.insert(conversation.objectID).inserted,
                      matchesVisibility(conversation) else {
                    continue
                }

                persistedVisibleConversations.append(conversation)
                guard persistedVisibleConversations.count < limit else { break }
            }

            fetchOffset += candidates.count
            guard candidates.count == candidateBatchSize else { break }
        }

        var conversationsByID = Dictionary(
            uniqueKeysWithValues: pendingVisibleConversations.map { ($0.objectID, $0) }
        )
        for conversation in persistedVisibleConversations {
            conversationsByID[conversation.objectID] = conversation
        }

        return Array(
            conversationsByID.values
                .sorted(by: sortsBefore(_:_:))
                .prefix(limit)
        )
    }

    /// Delegates to `ConversationListItem.SortKey` (the CANONICAL chat-list
    /// order) so the pending/persisted merge sorts pending rows exactly where
    /// a refetch would put them.
    private func sortsBefore(_ lhs: Conversation, _ rhs: Conversation) -> Bool {
        ConversationListItem.SortKey(conversation: lhs) < ConversationListItem.SortKey(conversation: rhs)
    }

    private func predicate(searchText: String, filter: ConversationFilter) -> NSPredicate {
        var predicates = [NSPredicate(format: "archivedAt == nil")]

        if filter == .unread {
            predicates.append(NSPredicate(format: "inboxUnreadCount > 0"))
        }

        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearchText.isEmpty {
            predicates.append(
                NSPredicate(
                    format: "(displayName CONTAINS[cd] %@) OR (snippet CONTAINS[cd] %@)",
                    trimmedSearchText,
                    trimmedSearchText
                )
            )
        }

        return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }
}
