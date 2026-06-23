import Foundation
import CoreData

struct ConversationListItem: Identifiable, Equatable {
    let id: NSManagedObjectID
    let snapshot: ConversationSnapshot

    init(conversation: Conversation) {
        self.id = conversation.objectID
        self.snapshot = ConversationSnapshot(from: conversation)
    }

    fileprivate var sortKey: SortKey {
        SortKey(pinned: snapshot.pinned, lastMessageDate: snapshot.lastMessageDate)
    }

    fileprivate struct SortKey: Equatable {
        let pinned: Bool
        let lastMessageDate: Date?
    }
}

struct ConversationWindowProvider {
    let initialLimit: Int
    let pageSize: Int
    let preloadThreshold: Int
    let contactFilterCandidateMultiplier: Int

    init(configuration: VirtualScrollConfiguration = .default) {
        self.initialLimit = configuration.pageSize * 2
        self.pageSize = configuration.pageSize
        self.preloadThreshold = configuration.preloadThreshold
        self.contactFilterCandidateMultiplier = 5
    }

    func window<C: Sequence>(
        from conversations: C,
        limit: Int,
        matchesVisibility: (Conversation) -> Bool
    ) -> [Conversation] where C.Element == Conversation {
        Array(conversations.lazy.filter(matchesVisibility).prefix(limit))
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
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Conversation.pinned, ascending: false),
            NSSortDescriptor(keyPath: \Conversation.lastMessageDate, ascending: false)
        ]
        request.predicate = predicate(searchText: searchText, filter: filter)
        request.fetchBatchSize = min(pageSize, max(limit, 1))
        request.relationshipKeyPathsForPrefetching = ["participants", "participants.person"]
        request.includesPendingChanges = true

        do {
            switch filter {
            case .all, .unread:
                request.fetchLimit = limit
                let candidates = try context.fetch(request)
                return Array(candidates.lazy.filter(matchesVisibility).prefix(limit))

            case .contacts, .other:
                return try fetchFilteredWindow(
                    request: request,
                    in: context,
                    limit: limit,
                    matchesVisibility: matchesVisibility
                )
            }
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
        var visibleConversations: [Conversation] = []
        var fetchOffset = 0
        let candidateBatchSize = max(limit * contactFilterCandidateMultiplier, limit, pageSize)

        while visibleConversations.count < limit {
            request.fetchOffset = fetchOffset
            request.fetchLimit = candidateBatchSize

            let candidates = try context.fetch(request)
            guard !candidates.isEmpty else { break }

            for conversation in candidates where matchesVisibility(conversation) {
                visibleConversations.append(conversation)
                guard visibleConversations.count < limit else { break }
            }

            fetchOffset += candidates.count
            guard candidates.count == candidateBatchSize else { break }
        }

        return visibleConversations
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

struct ConversationListStore {
    private(set) var itemsByID: [NSManagedObjectID: ConversationListItem] = [:]
    private(set) var orderedIDs: [NSManagedObjectID] = []
    private(set) var visibleIDs: [NSManagedObjectID] = []
    private(set) var visibleItems: [ConversationListItem] = []

    var isEmpty: Bool {
        orderedIDs.isEmpty && itemsByID.isEmpty
    }

    mutating func replaceAll(
        with conversations: [Conversation],
        matchesVisibility: (Conversation) -> Bool
    ) {
        itemsByID.removeAll(keepingCapacity: true)
        orderedIDs.removeAll(keepingCapacity: true)
        visibleIDs.removeAll(keepingCapacity: true)
        visibleItems.removeAll(keepingCapacity: true)

        for conversation in conversations {
            guard matchesVisibility(conversation) else { continue }

            let item = ConversationListItem(conversation: conversation)
            itemsByID[item.id] = item
            orderedIDs.append(item.id)
            visibleIDs.append(item.id)
            visibleItems.append(item)
        }
    }

    mutating func applyChanges(
        updatedConversations: [Conversation],
        deletedIDs: Set<NSManagedObjectID>,
        isSourceConversation: (Conversation) -> Bool,
        matchesVisibility: (Conversation) -> Bool
    ) -> Set<NSManagedObjectID> {
        var removedIDs = Set<NSManagedObjectID>()

        for objectID in deletedIDs {
            if removeConversation(withID: objectID) {
                removedIDs.insert(objectID)
            }
        }

        for conversation in updatedConversations {
            let objectID = conversation.objectID

            guard isSourceConversation(conversation) else {
                if removeConversation(withID: objectID) {
                    removedIDs.insert(objectID)
                }
                continue
            }

            upsertConversation(conversation, matchesVisibility: matchesVisibility)
        }

        return removedIDs
    }

    mutating func recomputeVisibleItems(
        matchesVisibility: (ConversationListItem) -> Bool
    ) {
        visibleIDs.removeAll(keepingCapacity: true)
        visibleItems.removeAll(keepingCapacity: true)

        for objectID in orderedIDs {
            guard let item = itemsByID[objectID], matchesVisibility(item) else { continue }
            visibleIDs.append(objectID)
            visibleItems.append(item)
        }
    }

    mutating func removeAll() {
        itemsByID.removeAll(keepingCapacity: true)
        orderedIDs.removeAll(keepingCapacity: true)
        visibleIDs.removeAll(keepingCapacity: true)
        visibleItems.removeAll(keepingCapacity: true)
    }

    mutating func trimVisibleItems(to limit: Int) -> Set<NSManagedObjectID> {
        guard visibleItems.count > limit else { return [] }

        let removedIDs = Set(visibleIDs.dropFirst(limit))
        visibleIDs = Array(visibleIDs.prefix(limit))
        visibleItems = Array(visibleItems.prefix(limit))
        orderedIDs.removeAll { removedIDs.contains($0) }

        for id in removedIDs {
            itemsByID.removeValue(forKey: id)
        }

        return removedIDs
    }

    private mutating func upsertConversation(
        _ conversation: Conversation,
        matchesVisibility: (Conversation) -> Bool
    ) {
        let objectID = conversation.objectID
        guard matchesVisibility(conversation) else {
            removeConversation(withID: objectID)
            return
        }

        let oldItem = itemsByID[objectID]
        let newItem = ConversationListItem(conversation: conversation)

        itemsByID[objectID] = newItem

        let needsReorder = oldItem == nil || oldItem?.sortKey != newItem.sortKey
        if needsReorder {
            moveOrderedConversation(objectID, item: newItem)
        } else if !orderedIDs.contains(objectID) {
            orderedIDs.append(objectID)
        }

        let currentVisibleIndex = visibleIDs.firstIndex(of: objectID)

        switch currentVisibleIndex {
        case .none:
            let insertionIndex = visibleInsertionIndex(for: objectID)
            visibleIDs.insert(objectID, at: insertionIndex)
            visibleItems.insert(newItem, at: insertionIndex)

        case let .some(index):
            if needsReorder {
                visibleIDs.remove(at: index)
                visibleItems.remove(at: index)

                let insertionIndex = visibleInsertionIndex(for: objectID)
                visibleIDs.insert(objectID, at: insertionIndex)
                visibleItems.insert(newItem, at: insertionIndex)
            } else {
                visibleItems[index] = newItem
            }
        }
    }

    @discardableResult
    private mutating func removeConversation(withID objectID: NSManagedObjectID) -> Bool {
        let existed = itemsByID.removeValue(forKey: objectID) != nil

        if let index = orderedIDs.firstIndex(of: objectID) {
            orderedIDs.remove(at: index)
        }

        if let index = visibleIDs.firstIndex(of: objectID) {
            visibleIDs.remove(at: index)
            visibleItems.remove(at: index)
        }

        return existed
    }

    private mutating func moveOrderedConversation(_ objectID: NSManagedObjectID, item: ConversationListItem) {
        if let index = orderedIDs.firstIndex(of: objectID) {
            orderedIDs.remove(at: index)
        }

        let insertionIndex = orderedIDs.firstIndex { existingID in
            guard let existingItem = itemsByID[existingID] else { return false }
            return sortsBefore(item, existingItem)
        } ?? orderedIDs.endIndex

        orderedIDs.insert(objectID, at: insertionIndex)
    }

    private func visibleInsertionIndex(for objectID: NSManagedObjectID) -> Int {
        guard let orderedIndex = orderedIDs.firstIndex(of: objectID) else {
            return visibleIDs.count
        }

        let visibleSet = Set(visibleIDs)
        var count = 0

        for id in orderedIDs[..<orderedIndex] where visibleSet.contains(id) {
            count += 1
        }

        return count
    }

    private func sortsBefore(_ lhs: ConversationListItem, _ rhs: ConversationListItem) -> Bool {
        if lhs.snapshot.pinned != rhs.snapshot.pinned {
            return lhs.snapshot.pinned && !rhs.snapshot.pinned
        }

        let lhsDate = lhs.snapshot.lastMessageDate ?? .distantPast
        let rhsDate = rhs.snapshot.lastMessageDate ?? .distantPast

        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }

        return false
    }
}
