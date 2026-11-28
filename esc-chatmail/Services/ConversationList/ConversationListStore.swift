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
///
/// The window is a prefix of the store's matching rows in `SortKey` order, and
/// `edge` says where it ends. While rows may exist past it, a live change is
/// admitted only for a row that sorts at or before the edge: one past it is not
/// added (a page or the backfill reaches it in order), and a window row that
/// moves past it leaves. Until 2026-11-28 every visible change was upserted, so a
/// row that moved past the tail (unpinned, or its newest message gone) stayed at
/// the window's end ahead of rows that sort before it, which only a full reload
/// healed, and a catch-up save of rows far past the window had their
/// participants fetched and snapshotted on the main thread before the trim
/// dropped them (architecture review 2026-11, conversation-list-ui#3 step 1,
/// conversation-list-ui#5).
struct ConversationListStore {
    /// Where the window ends in the store's order.
    enum Edge: Equatable {
        /// The window holds every row that matches its query, so any change is admitted.
        case complete
        /// Rows may exist in the store past the window. Every matching row that sorts
        /// at or before `after` is in the window; nil when the window holds no prefix
        /// at all (emptied by an invalidate-all, or a first fetch that failed), where
        /// nothing is admitted until a fetch says what the prefix is.
        case open(after: ConversationListItem.SortKey?)
    }

    /// What a live change to one row does to the window (`admittance(of:isSourceConversation:)`).
    enum Admittance: Equatable {
        /// The row may be in the window after the change: it is upserted.
        case admitted
        /// The row is in the window and the change takes it out (archived, a
        /// tombstone, or moved past the edge).
        case leaves
        /// The row is not in the window and the change does not bring it in.
        case outside
    }

    /// Snapshot lookup keyed by objectID; always holds exactly the rows of
    /// `visibleItems`. Kept so `upsertConversation` can compare the old
    /// `sortKey` and `removeConversation` can report prior membership.
    private var itemsByID: [NSManagedObjectID: ConversationListItem] = [:]
    /// The published window, ordered by `sortsBefore(_:_:)` (`replaceAll`
    /// trusts the caller's order instead — see its doc).
    private(set) var visibleItems: [ConversationListItem] = []
    /// Where the window ends; see the type's doc.
    private(set) var edge: Edge = .complete

    /// Whether the window holds every matching row, so paging and the backfill have
    /// nothing to fetch.
    var isComplete: Bool {
        edge == .complete
    }

    /// Whether the row is in the window.
    func contains(_ objectID: NSManagedObjectID) -> Bool {
        itemsByID[objectID] != nil
    }

    /// Replaces the store contents with an already-filtered, already-sorted
    /// window in the caller's order. The only caller passes the result of
    /// `fetchWindow`, which applied the visibility filter and sort, so the
    /// store deliberately does not re-filter or re-sort here. A row the list
    /// cannot show (`ConversationListItem.init?(conversation:)`) is skipped.
    /// `isComplete` is whether the fetch returned every matching row; otherwise
    /// the window's last row is its edge.
    mutating func replaceAll(with conversations: [Conversation], isComplete: Bool) {
        itemsByID.removeAll(keepingCapacity: true)
        visibleItems.removeAll(keepingCapacity: true)

        for conversation in conversations {
            guard let item = ConversationListItem(conversation: conversation) else { continue }
            itemsByID[item.id] = item
            visibleItems.append(item)
        }
        edge = isComplete ? .complete : .open(after: visibleItems.last?.sortKey)
    }

    /// A fetch of the window failed, so the store can no longer say the window is
    /// complete. A window that was a prefix stays one, ending at its last row; an
    /// open edge is kept as it is.
    mutating func markOpen() {
        guard edge == .complete else { return }
        edge = .open(after: visibleItems.last?.sortKey)
    }

    /// Whether a row with this key, after a change, belongs in the window: any row of
    /// a complete window, else one that sorts at or before the edge.
    func admits(sortKey: ConversationListItem.SortKey) -> Bool {
        switch edge {
        case .complete:
            return true
        case .open(after: let boundary?):
            return !(boundary < sortKey)
        case .open(after: nil):
            return false
        }
    }

    /// What a live change to `conversation` does to the window. Reads the row's own
    /// attributes and nothing of its participants, so the sibling-save path can ask it
    /// before it prefetches them. `isSourceConversation` is the list's source test (not
    /// archived); visibility is not asked here, because it may read participants.
    func admittance(
        of conversation: Conversation,
        isSourceConversation: (Conversation) -> Bool
    ) -> Admittance {
        if isSourceConversation(conversation),
           let sortKey = ConversationListItem.SortKey(listableConversation: conversation),
           admits(sortKey: sortKey) {
            return .admitted
        }
        return contains(conversation.objectID) ? .leaves : .outside
    }

    /// Applies one objectsDidChange/didSave batch: removes `deletedIDs` and
    /// the rows the change takes out of the window (`admittance`), upserts the
    /// admitted ones and passes over the rest. Returns the IDs of removed rows
    /// that were present; a row dropped because it stopped matching
    /// `matchesVisibility` is deliberately not reported (the view model
    /// reconciles selection against the visible rows on every publish).
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

            switch admittance(of: conversation, isSourceConversation: isSourceConversation) {
            case .admitted:
                upsertConversation(conversation, matchesVisibility: matchesVisibility)
            case .leaves:
                if removeConversation(withID: objectID) {
                    removedIDs.insert(objectID)
                }
            case .outside:
                continue
            }
        }

        return removedIDs
    }

    /// Empties the store (invalidate-all teardown path). The edge opens with no
    /// prefix: until a fetch says what the window is, nothing is admitted.
    mutating func removeAll() {
        itemsByID.removeAll(keepingCapacity: true)
        visibleItems.removeAll(keepingCapacity: true)
        edge = .open(after: nil)
    }

    /// Drops every row past `limit` and returns the trimmed IDs. A non-empty trim
    /// proves the store holds rows beyond the window, so the edge opens at the new
    /// last row, which reopens paging even after a short first fetch had found the
    /// window complete.
    mutating func trimVisibleItems(to limit: Int) -> Set<NSManagedObjectID> {
        guard visibleItems.count > limit else { return [] }

        let removedIDs = Set(visibleItems.dropFirst(limit).map(\.id))
        visibleItems = Array(visibleItems.prefix(limit))

        for id in removedIDs {
            itemsByID.removeValue(forKey: id)
        }
        edge = .open(after: visibleItems.last?.sortKey)

        return removedIDs
    }

    /// Inserts or refreshes one visible row: an unchanged `sortKey` replaces
    /// the snapshot in place; otherwise the row leaves its old position and
    /// re-enters at its `sortsBefore(_:_:)` position. A row failing
    /// `matchesVisibility`, or one the list cannot show
    /// (`ConversationListItem.init?(conversation:)`), is removed instead: only
    /// skipped, a tombstone's stale row would stay on screen.
    private mutating func upsertConversation(
        _ conversation: Conversation,
        matchesVisibility: (Conversation) -> Bool
    ) {
        let objectID = conversation.objectID
        guard matchesVisibility(conversation),
              let newItem = ConversationListItem(conversation: conversation) else {
            removeConversation(withID: objectID)
            return
        }

        let oldItem = itemsByID[objectID]

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
