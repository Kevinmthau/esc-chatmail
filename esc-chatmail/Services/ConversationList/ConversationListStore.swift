import Foundation
import CoreData

private func uuidSortsBefore(_ lhs: UUID, _ rhs: UUID) -> Bool {
    (lhs as NSUUID).compare(rhs) == .orderedAscending
}

struct ConversationListItem: Identifiable, Equatable {
    let id: NSManagedObjectID
    let snapshot: ConversationSnapshot
    private let stableID: UUID

    init(conversation: Conversation) {
        self.id = conversation.objectID
        self.snapshot = ConversationSnapshot(from: conversation)
        self.stableID = conversation.id
    }

    fileprivate var sortKey: SortKey {
        SortKey(
            pinned: snapshot.pinned,
            lastMessageDate: snapshot.lastMessageDate,
            stableID: stableID
        )
    }

    fileprivate struct SortKey: Equatable {
        let pinned: Bool
        let lastMessageDate: Date?
        let stableID: UUID
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

    private func sortsBefore(_ lhs: Conversation, _ rhs: Conversation) -> Bool {
        if lhs.pinned != rhs.pinned {
            return lhs.pinned && !rhs.pinned
        }

        let lhsDate = lhs.lastMessageDate ?? .distantPast
        let rhsDate = rhs.lastMessageDate ?? .distantPast
        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }

        return uuidSortsBefore(lhs.id, rhs.id)
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

/// In-memory reducer for the conversation list's published window.
///
/// F9 step 2 collapsed the former `orderedIDs`/`visibleIDs`/`visibleItems`
/// parallel indexes into the single ordered `visibleItems` list: with the
/// in-memory recompute path retired, visibility is applied at ingestion, so
/// the ordered and visible sets can never diverge and one list suffices.
/// Linear scans are deliberate — the window holds a few hundred rows at most,
/// so an index dictionary or binary search would buy nothing but complexity.
struct ConversationListStore {
    /// Snapshot lookup keyed by objectID; always holds exactly the rows of
    /// `visibleItems`. Kept so `upsertConversation` can compare the old
    /// `sortKey` and `removeConversation` can report prior membership.
    private var itemsByID: [NSManagedObjectID: ConversationListItem] = [:]
    /// The published window, ordered by `sortsBefore(_:_:)` (`replaceAll`
    /// trusts the caller's order instead — see its doc).
    private(set) var visibleItems: [ConversationListItem] = []

    /// Replaces the store contents with an already-filtered, already-sorted
    /// window in the caller's order. The only caller passes the result of
    /// `fetchWindow`, which applied the visibility filter and sort, so the
    /// store deliberately does not re-filter or re-sort here.
    mutating func replaceAll(with conversations: [Conversation]) {
        itemsByID.removeAll(keepingCapacity: true)
        visibleItems.removeAll(keepingCapacity: true)

        for conversation in conversations {
            let item = ConversationListItem(conversation: conversation)
            itemsByID[item.id] = item
            visibleItems.append(item)
        }
    }

    /// Applies one objectsDidChange/didSave batch: removes `deletedIDs` and
    /// rows failing `isSourceConversation`, upserts the rest. Returns the IDs
    /// of removed rows that were present; a row dropped because it stopped
    /// matching `matchesVisibility` is deliberately not reported (the view
    /// model reconciles selection against the visible rows on every publish).
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

    /// Empties the store (invalidate-all teardown path).
    mutating func removeAll() {
        itemsByID.removeAll(keepingCapacity: true)
        visibleItems.removeAll(keepingCapacity: true)
    }

    /// Drops every row past `limit` and returns the trimmed IDs, so the
    /// caller can reopen paging when the store held rows beyond the window.
    mutating func trimVisibleItems(to limit: Int) -> Set<NSManagedObjectID> {
        guard visibleItems.count > limit else { return [] }

        let removedIDs = Set(visibleItems.dropFirst(limit).map(\.id))
        visibleItems = Array(visibleItems.prefix(limit))

        for id in removedIDs {
            itemsByID.removeValue(forKey: id)
        }

        return removedIDs
    }

    /// Inserts or refreshes one visible row: an unchanged `sortKey` replaces
    /// the snapshot in place; otherwise the row leaves its old position and
    /// re-enters at its `sortsBefore(_:_:)` position. A row failing
    /// `matchesVisibility` is removed instead.
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

        let existingIndex = visibleItems.firstIndex { $0.id == objectID }

        if let existingIndex, oldItem?.sortKey == newItem.sortKey {
            visibleItems[existingIndex] = newItem
            return
        }

        if let existingIndex {
            visibleItems.remove(at: existingIndex)
        }

        let insertionIndex = visibleItems.firstIndex { existingItem in
            Self.sortsBefore(newItem, existingItem)
        } ?? visibleItems.endIndex
        visibleItems.insert(newItem, at: insertionIndex)
    }

    /// Removes one row; returns whether it was present.
    @discardableResult
    private mutating func removeConversation(withID objectID: NSManagedObjectID) -> Bool {
        let existed = itemsByID.removeValue(forKey: objectID) != nil

        if let index = visibleItems.firstIndex(where: { $0.id == objectID }) {
            visibleItems.remove(at: index)
        }

        return existed
    }

    /// THE list-item comparator: pinned first, then lastMessageDate
    /// descending, then conversation UUID ascending — matching
    /// `ConversationWindowProvider`'s NSSortDescriptor order so live upserts
    /// land where a refetch would put them (the equal-timestamp UUID
    /// tie-break keeps row identity stable across expansion, live insert,
    /// and reappearance). Internal so tests can assert `visibleItems` stays
    /// sorted by it.
    static func sortsBefore(_ lhs: ConversationListItem, _ rhs: ConversationListItem) -> Bool {
        if lhs.snapshot.pinned != rhs.snapshot.pinned {
            return lhs.snapshot.pinned && !rhs.snapshot.pinned
        }

        let lhsDate = lhs.snapshot.lastMessageDate ?? .distantPast
        let rhsDate = rhs.snapshot.lastMessageDate ?? .distantPast

        if lhsDate != rhsDate {
            return lhsDate > rhsDate
        }

        return uuidSortsBefore(lhs.sortKey.stableID, rhs.sortKey.stableID)
    }
}
