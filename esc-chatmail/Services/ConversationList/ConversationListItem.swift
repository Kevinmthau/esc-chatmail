import Foundation
import CoreData

struct ConversationListItem: Identifiable, Equatable {
    let snapshot: ConversationSnapshot
    private let stableID: UUID

    /// The row's `Identifiable` identity — reads `snapshot.objectID` instead of
    /// storing a duplicate copy of the same `NSManagedObjectID`.
    var id: NSManagedObjectID {
        snapshot.objectID
    }

    /// Nil for a row the list cannot show: one deleted in its context, or a tombstone, the
    /// fault of a row another context deleted from the store before it fired, which reads
    /// nil for every attribute (`shouldDeleteInaccessibleFaults`). Its non-optional `id` and
    /// `type` would trap in the snapshot, so the check reads the ID through KVC first, and
    /// nothing else is read when it fails. `ConversationListStore` skips such a row on a
    /// reload and removes it on a live change (architecture review 2026-11,
    /// conversation-list-ui#4). Never make `Conversation.id` optional for this: that is a
    /// model change.
    init?(conversation: Conversation) {
        guard let stableID = Self.listableID(of: conversation) else { return nil }
        self.snapshot = ConversationSnapshot(from: conversation)
        self.stableID = stableID
    }

    /// The conversation's UUID when the list can show it, read without trapping: nil for a
    /// deleted row or a tombstone (see `init?(conversation:)`). The one definition of a row
    /// the list can show; `ConversationWindowProvider` asks it before it sorts a row.
    static func listableID(of conversation: Conversation) -> UUID? {
        guard !conversation.isDeleted else { return nil }
        return conversation.value(forKey: "id") as? UUID
    }

    /// This item's position in the CANONICAL chat-list order. Internal (was
    /// `fileprivate` when the store shared this file) because
    /// `ConversationListStore.sortsBefore(_:_:)` and its upsert path read it
    /// across the F14 file split.
    var sortKey: SortKey {
        SortKey(
            pinned: snapshot.pinned,
            lastMessageDate: snapshot.lastMessageDate,
            stableID: stableID
        )
    }

    /// CANONICAL chat-list ordering — the single owner of the
    /// (pinned desc, lastMessageDate desc, conversation-UUID asc) order.
    /// Every Swift comparator on the list delegates to `<`; do not duplicate
    /// the comparison. The `NSSortDescriptor`s in
    /// `ConversationWindowProvider.fetchWindow` are this key's SQL mirror
    /// (SQLite cannot call a Swift comparator) and must stay in exact
    /// agreement with it.
    struct SortKey: Equatable, Comparable {
        let pinned: Bool
        let lastMessageDate: Date?
        let stableID: UUID

        init(pinned: Bool, lastMessageDate: Date?, stableID: UUID) {
            self.pinned = pinned
            self.lastMessageDate = lastMessageDate
            self.stableID = stableID
        }

        /// Builds the key straight from a managed `Conversation` — the
        /// counterpart of `ConversationListItem.sortKey` for rows that have
        /// no list item yet (`ConversationWindowProvider`'s pending/persisted
        /// merge sort).
        init(conversation: Conversation) {
            self.init(
                pinned: conversation.pinned,
                lastMessageDate: conversation.lastMessageDate,
                stableID: conversation.id
            )
        }

        /// "Sorts before" as `<`: pinned rows first, then later
        /// `lastMessageDate` first (nil as `.distantPast`), then conversation
        /// UUID ascending via `NSUUID` comparison — the equal-timestamp UUID
        /// tie-break keeps row identity stable across expansion, live insert,
        /// and reappearance.
        static func < (lhs: SortKey, rhs: SortKey) -> Bool {
            if lhs.pinned != rhs.pinned {
                return lhs.pinned && !rhs.pinned
            }

            let lhsDate = lhs.lastMessageDate ?? .distantPast
            let rhsDate = rhs.lastMessageDate ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }

            return (lhs.stableID as NSUUID).compare(rhs.stableID) == .orderedAscending
        }
    }
}
