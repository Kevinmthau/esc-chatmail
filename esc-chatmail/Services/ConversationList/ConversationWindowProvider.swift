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

    /// A window read from the store: its rows, and whether they are every row that
    /// matches the query.
    struct Window {
        let rows: [Conversation]
        /// Read from what the store returned, never from `rows.count`: a row the list
        /// cannot show (a tombstone, `ConversationListItem.listableID(of:)`) is dropped
        /// from `rows` after the fetch, and a window one row short of the limit for it
        /// is not the end of the store's rows (PR 527's review: counted from `rows`, a
        /// tombstone closed paging for good, and on the Mac nothing reloads).
        let isComplete: Bool
    }

    /// The window's rows (`fetchWindowReportingCompleteness(...).rows`).
    func fetchWindow(
        in context: NSManagedObjectContext,
        limit: Int,
        searchText: String,
        filter: ConversationFilter,
        canMatchCurrentFilter: Bool = true,
        matchesVisibility: (Conversation) -> Bool
    ) throws -> [Conversation] {
        try fetchWindowReportingCompleteness(
            in: context,
            limit: limit,
            searchText: searchText,
            filter: filter,
            canMatchCurrentFilter: canMatchCurrentFilter,
            matchesVisibility: matchesVisibility
        ).rows
    }

    /// Throws when the store cannot be read. A failed read is not an empty mailbox
    /// (CLAUDE.md): answered as `[]`, as until 2026-11-27, it was the same value as a
    /// genuinely empty store, so the list latched "all loaded" on it, replaced a
    /// populated window with nothing and paged no more (architecture review 2026-11,
    /// conversation-list-ui#6). The two empty answers that stay are deliberate: nothing
    /// asked for (not complete, as before: `0 < 0` never latched), and a filter that can
    /// match nothing (complete).
    func fetchWindowReportingCompleteness(
        in context: NSManagedObjectContext,
        limit: Int,
        searchText: String,
        filter: ConversationFilter,
        canMatchCurrentFilter: Bool = true,
        matchesVisibility: (Conversation) -> Bool
    ) throws -> Window {
        guard limit > 0 else { return Window(rows: [], isComplete: false) }
        guard canMatchCurrentFilter else { return Window(rows: [], isComplete: true) }

        let request = windowRequest(
            predicate: predicate(searchText: searchText, filter: filter),
            limit: limit
        )

        let hasSearchText = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Why some fetches must page past SQL-invisible candidates is
        // documented on ConversationFilter.needsInMemoryCandidateScan(hasSearchText:).
        let shouldFetchPastInvisibleCandidates = filter.needsInMemoryCandidateScan(hasSearchText: hasSearchText)

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
        return Window(
            rows: Array(candidates.filter { Self.isListable($0) && matchesVisibility($0) }.prefix(limit)),
            isComplete: candidates.count < limit
        )
    }

    /// Whether the query can be paged by keyset (`fetchPage`): its store predicate is
    /// exact, so the store's next rows in the window's order are the window's next rows. A
    /// search or the contact filters re-check rows in memory
    /// (`ConversationFilter.needsInMemoryCandidateScan`) and keep the full reload.
    func pagesByKeyset(searchText: String, filter: ConversationFilter) -> Bool {
        let hasSearchText = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !filter.needsInMemoryCandidateScan(hasSearchText: hasSearchText)
    }

    /// The next `limit` rows of the window after `edge` (the sort key of the window's last
    /// row, `ConversationListStore.pageStartKey`), in the window's order: one fetch of
    /// `limit` rows, where a page or a backfill used to reload the whole window from its
    /// first row on the main thread (architecture review 2026-11, conversation-list-ui#3).
    /// Only for a query `pagesByKeyset` allows.
    ///
    /// `isComplete` is read from what the store returned, before a row the list cannot
    /// show is dropped (as for `fetchWindowReportingCompleteness`): a short page is the end
    /// of the store's rows, a dropped tombstone is not. Pending changes are included, as in `fetchWindow`'s plain path, so an
    /// unsaved optimistic row past the edge is in the page; the keyset term gives the
    /// same answer in memory as in SQLite (`SortKey.storePredicateForRowsAfter`). Throws
    /// when the store cannot be read, like `fetchWindow`.
    func fetchPage(
        in context: NSManagedObjectContext,
        after edge: ConversationListItem.SortKey,
        limit: Int,
        filter: ConversationFilter,
        matchesVisibility: (Conversation) -> Bool
    ) throws -> Window {
        guard limit > 0 else { return Window(rows: [], isComplete: false) }

        let request = windowRequest(
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                predicate(searchText: "", filter: filter),
                edge.storePredicateForRowsAfter
            ]),
            limit: limit
        )
        request.fetchLimit = limit
        // Every row of a page is snapshotted at once, so batching it only adds Core Data's
        // own `SELF IN $batch` fetch after the page's (measured 2026-11-28).
        request.fetchBatchSize = 0
        let fetched = try context.fetch(request)
        return Window(
            rows: fetched.filter { Self.isListable($0) && matchesVisibility($0) },
            isComplete: fetched.count < limit
        )
    }

    /// The window's request: its order, its prefetch, and pending changes included.
    private func windowRequest(predicate: NSPredicate, limit: Int) -> NSFetchRequest<Conversation> {
        let request = NSFetchRequest<Conversation>(entityName: "Conversation")
        // SQL mirror of ConversationListItem.SortKey's `<` — the CANONICAL
        // chat-list order. SQLite cannot call the Swift comparator, so these
        // descriptors must stay in exact agreement with it: pinned desc,
        // lastMessageDate desc (nil/NULL last on both sides), conversation
        // UUID asc. A page's keyset term (`SortKey.storePredicateForRowsAfter`)
        // is the same order's predicate.
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Conversation.pinned, ascending: false),
            NSSortDescriptor(keyPath: \Conversation.lastMessageDate, ascending: false),
            NSSortDescriptor(keyPath: \Conversation.id, ascending: true)
        ]
        request.predicate = predicate
        request.fetchBatchSize = min(pageSize, max(limit, 1))
        request.relationshipKeyPathsForPrefetching = ["participants", "participants.person"]
        request.includesPendingChanges = true
        return request
    }

    /// Complete when the scan ran out of the store's rows before it found `limit`
    /// visible ones (the loop below leaves early only on reaching `limit`) and the
    /// context's pending rows, merged in, still fit: a dropped tombstone is not counted,
    /// so it keeps the scan going instead of ending it.
    private func fetchFilteredWindow(
        request: NSFetchRequest<Conversation>,
        in context: NSManagedObjectContext,
        limit: Int,
        matchesVisibility: (Conversation) -> Bool
    ) throws -> Window {
        let pendingObjects = context.insertedObjects
            .union(context.updatedObjects)
            .union(context.deletedObjects)
        let pendingConversations = pendingObjects.compactMap { $0 as? Conversation }
        let pendingIDs = Set(pendingConversations.map(\.objectID))
        let pendingVisibleConversations = pendingConversations
            .filter { conversation in
                Self.isListable(conversation) &&
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
                      Self.isListable(conversation),
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

        return Window(
            rows: Array(
                conversationsByID.values
                    .sorted(by: sortsBefore(_:_:))
                    .prefix(limit)
            ),
            isComplete: persistedVisibleConversations.count < limit && conversationsByID.count <= limit
        )
    }

    /// Whether the list can show the row (`ConversationListItem.listableID(of:)`): a
    /// returned fault whose row another context deleted before it fired is a tombstone,
    /// and `SortKey(conversation:)` below and the list item would trap on its nil `id`.
    /// Asked before the sort and the visibility check, so neither reads one.
    private static func isListable(_ conversation: Conversation) -> Bool {
        ConversationListItem.listableID(of: conversation) != nil
    }

    /// Delegates to `ConversationListItem.SortKey` (the CANONICAL chat-list
    /// order) so the pending/persisted merge sorts pending rows exactly where
    /// a refetch would put them.
    private func sortsBefore(_ lhs: Conversation, _ rhs: Conversation) -> Bool {
        ConversationListItem.SortKey(conversation: lhs) < ConversationListItem.SortKey(conversation: rhs)
    }

    private func predicate(searchText: String, filter: ConversationFilter) -> NSPredicate {
        var predicates = [NSPredicate(format: "archivedAt == nil")]

        if let filterPredicate = filter.storePredicate {
            predicates.append(filterPredicate)
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
