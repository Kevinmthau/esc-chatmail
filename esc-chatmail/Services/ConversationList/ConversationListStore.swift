import Foundation
import CoreData

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

    /// THE list-item comparator, delegating to `ConversationListItem.SortKey`
    /// (the CANONICAL chat-list order, mirrored by
    /// `ConversationWindowProvider`'s NSSortDescriptors) so live upserts land
    /// where a refetch would put them — the equal-timestamp UUID tie-break
    /// keeps row identity stable across expansion, live insert, and
    /// reappearance. Internal so tests can assert `visibleItems` stays sorted
    /// by it.
    static func sortsBefore(_ lhs: ConversationListItem, _ rhs: ConversationListItem) -> Bool {
        lhs.sortKey < rhs.sortKey
    }
}
