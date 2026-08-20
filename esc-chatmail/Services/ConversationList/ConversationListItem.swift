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

    init(conversation: Conversation) {
        self.snapshot = ConversationSnapshot(from: conversation)
        self.stableID = conversation.id
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
