import Foundation
import CoreData

/// Tracks modified conversation IDs per sync run so rollup work is isolated
/// until the run that made the changes is ready to consume them.
actor ModificationTracker {
    struct Transaction: Sendable, Hashable {
        fileprivate let id: UUID
    }

    private struct ConversationModifications: Equatable {
        var rollupIDs: Set<NSManagedObjectID>
        /// Rollup IDs already handed to a mid-run consumer (per-page rollups).
        /// Kept separate so re-tracking a claimed conversation re-pends it.
        var claimedRollupIDs: Set<NSManagedObjectID>
        var displayNameOnlyIDs: Set<NSManagedObjectID>
        /// Display-name-only IDs whose names a mid-run consumer has refreshed,
        /// kept apart for the same reason: tracking one again re-pends it.
        var claimedDisplayNameOnlyIDs: Set<NSManagedObjectID>

        static let empty = ConversationModifications(
            rollupIDs: [],
            claimedRollupIDs: [],
            displayNameOnlyIDs: [],
            claimedDisplayNameOnlyIDs: []
        )

        var trackedCount: Int {
            rollupIDs.union(claimedRollupIDs).count
                + displayNameOnlyIDs.union(claimedDisplayNameOnlyIDs).count
        }

        /// Moves the pending rollup IDs to the claimed set, with the pending
        /// display-name-only entries of the same conversations: a rollup
        /// refreshes the stored title too (`ConversationRollupUpdater.updateRollups`
        /// ends with `updateDisplayNameOnly`), so the name refresh is done once
        /// the rollup is. Left pending, a later consumer refreshed those names
        /// again, which walks every message of the conversation.
        mutating func claimPendingRollups() -> Set<NSManagedObjectID> {
            let claimed = rollupIDs
            claimedRollupIDs.formUnion(claimed)
            rollupIDs = []
            let refreshedNames = displayNameOnlyIDs.intersection(claimed)
            displayNameOnlyIDs.subtract(refreshedNames)
            claimedDisplayNameOnlyIDs.formUnion(refreshedNames)
            return claimed
        }
    }

    /// What a mid-run consumer that refreshes both rollups and names claims
    /// (`claimPendingConversationUpdates`): the conversations to roll up, and
    /// the others whose names alone need refreshing. The two never overlap.
    struct ClaimedConversationUpdates: Equatable, Sendable {
        let rollupIDs: Set<NSManagedObjectID>
        let displayNameOnlyIDs: Set<NSManagedObjectID>
    }

    private enum TransactionState {
        case active(ConversationModifications)
        case committed(ConversationModifications)

        var modifications: ConversationModifications {
            switch self {
            case .active(let modifications), .committed(let modifications):
                modifications
            }
        }
    }

    static let shared = ModificationTracker()

    private var transactions: [UUID: TransactionState] = [:]

    private init() {}

    // MARK: - Transactions

    func beginTransaction() -> Transaction {
        let transaction = Transaction(id: UUID())
        transactions[transaction.id] = .active(.empty)
        Log.debug("Started modification transaction: \(transaction.id)", category: .sync)
        return transaction
    }

    /// Returns the run's current modified conversations without changing transaction state.
    func modifiedConversations(in transaction: Transaction) -> Set<NSManagedObjectID> {
        guard let state = transactions[transaction.id] else {
            Log.warning("Attempted to read unknown transaction \(transaction.id)", category: .sync)
            return []
        }

        return state.modifications.rollupIDs
    }

    /// Moves the run's pending rollup IDs to the claimed set and returns them, so a
    /// mid-run consumer (per-page rollups) can process each modification exactly once.
    /// Tracking the same conversation again after a claim re-pends it for the next
    /// claim, which keeps a conversation modified on a later page eligible for
    /// another rollup. Valid only on active transactions.
    func claimPendingRollupConversations(in transaction: Transaction) -> Set<NSManagedObjectID> {
        guard let state = transactions[transaction.id] else {
            Log.warning("Attempted to claim rollups for unknown transaction \(transaction.id)", category: .sync)
            return []
        }

        switch state {
        case .active(var modifications):
            guard !modifications.rollupIDs.isEmpty else { return [] }
            let claimed = modifications.claimPendingRollups()
            transactions[transaction.id] = .active(modifications)
            Log.debug(
                "Claimed \(claimed.count) pending rollup conversations in transaction \(transaction.id)",
                category: .sync
            )
            return claimed
        case .committed:
            Log.warning("Attempted to claim rollups on committed transaction \(transaction.id)", category: .sync)
            return []
        }
    }

    /// Claims every pending update, rollups and names alike, for a mid-run
    /// consumer that applies both and saves them (the incremental run's
    /// intermediate flush). What it claims is not handed out again: the run's
    /// final save rolls up and renames only what was tracked after the claim,
    /// so every writer after it must track what it changes, as every writer
    /// does today (architecture review 2026-11, data-model#4). Until
    /// 2026-11-28 the flush read without claiming, and the final save rolled
    /// up every conversation the flush had already rolled up, walking each
    /// one's messages a second time. Valid only on active transactions.
    func claimPendingConversationUpdates(in transaction: Transaction) -> ClaimedConversationUpdates {
        let none = ClaimedConversationUpdates(rollupIDs: [], displayNameOnlyIDs: [])
        guard let state = transactions[transaction.id] else {
            Log.warning("Attempted to claim conversation updates for unknown transaction \(transaction.id)", category: .sync)
            return none
        }

        switch state {
        case .active(var modifications):
            let rollupIDs = modifications.claimPendingRollups()
            let displayNameOnlyIDs = modifications.displayNameOnlyIDs
            modifications.claimedDisplayNameOnlyIDs.formUnion(displayNameOnlyIDs)
            modifications.displayNameOnlyIDs = []
            transactions[transaction.id] = .active(modifications)
            return ClaimedConversationUpdates(rollupIDs: rollupIDs, displayNameOnlyIDs: displayNameOnlyIDs)
        case .committed:
            Log.warning("Attempted to claim conversation updates on committed transaction \(transaction.id)", category: .sync)
            return none
        }
    }

    /// Returns the conversations whose names alone are pending a refresh:
    /// tracked display-name-only and not claimed since.
    func displayNameOnlyConversations(in transaction: Transaction) -> Set<NSManagedObjectID> {
        guard let state = transactions[transaction.id] else {
            Log.warning("Attempted to read display-name-only changes for unknown transaction \(transaction.id)", category: .sync)
            return []
        }

        return state.modifications.displayNameOnlyIDs
    }

    /// Marks the run's modifications as ready for rollup updates after persistence succeeds.
    func commitTransaction(_ transaction: Transaction) -> Set<NSManagedObjectID> {
        guard let state = transactions[transaction.id] else {
            Log.warning("Attempted to commit unknown transaction \(transaction.id)", category: .sync)
            return []
        }

        switch state {
        case .active(let modifications):
            transactions[transaction.id] = .committed(modifications)
            Log.debug(
                "Committed modification transaction \(transaction.id) with \(modifications.trackedCount) conversations",
                category: .sync
            )
            return modifications.rollupIDs
        case .committed(let modifications):
            Log.warning("Transaction \(transaction.id) was already committed", category: .sync)
            return modifications.rollupIDs
        }
    }

    /// Clears a committed transaction after rollup updates successfully consume it.
    func consumeCommittedTransaction(_ transaction: Transaction) {
        guard let state = transactions[transaction.id] else {
            Log.warning("Attempted to consume unknown transaction \(transaction.id)", category: .sync)
            return
        }

        switch state {
        case .active:
            Log.warning("Attempted to consume active transaction \(transaction.id) before commit", category: .sync)
        case .committed(let modifications):
            transactions.removeValue(forKey: transaction.id)
            Log.debug(
                "Consumed committed transaction \(transaction.id) with \(modifications.trackedCount) conversations",
                category: .sync
            )
        }
    }

    /// Discards a run that never reached the persistence success boundary.
    /// Already-committed transactions are left intact so persisted work is not dropped.
    func rollbackTransaction(_ transaction: Transaction) {
        guard let state = transactions[transaction.id] else {
            Log.warning("Attempted to rollback unknown transaction \(transaction.id)", category: .sync)
            return
        }

        switch state {
        case .active(let modifications):
            transactions.removeValue(forKey: transaction.id)
            Log.debug(
                "Rolled back modification transaction \(transaction.id) with \(modifications.trackedCount) conversations",
                category: .sync
            )
        case .committed:
            Log.warning("Attempted to rollback committed transaction \(transaction.id); leaving it pending", category: .sync)
        }
    }

    // MARK: - Tracking

    func trackModifiedConversation(
        _ objectID: NSManagedObjectID,
        in transaction: Transaction?
    ) {
        guard let transaction else { return }

        guard let state = transactions[transaction.id] else {
            Log.warning("Attempted to track modification for unknown transaction \(transaction.id)", category: .sync)
            return
        }

        switch state {
        case .active(var modifications):
            modifications.rollupIDs.insert(objectID)
            transactions[transaction.id] = .active(modifications)
        case .committed:
            Log.warning("Attempted to track modification on committed transaction \(transaction.id)", category: .sync)
        }
    }

    func trackModifiedConversations(
        _ objectIDs: [NSManagedObjectID],
        in transaction: Transaction?
    ) {
        for objectID in objectIDs {
            trackModifiedConversation(objectID, in: transaction)
        }
    }

    func trackModifiedConversations(
        _ objectIDs: Set<NSManagedObjectID>,
        in transaction: Transaction?
    ) {
        guard let transaction else { return }

        guard let state = transactions[transaction.id] else {
            Log.warning("Attempted to track modifications for unknown transaction \(transaction.id)", category: .sync)
            return
        }

        switch state {
        case .active(var modifications):
            modifications.rollupIDs.formUnion(objectIDs)
            transactions[transaction.id] = .active(modifications)
        case .committed:
            Log.warning("Attempted to track modifications on committed transaction \(transaction.id)", category: .sync)
        }
    }

    func trackDisplayNameOnlyConversations(
        _ objectIDs: Set<NSManagedObjectID>,
        in transaction: Transaction?
    ) {
        guard let transaction, !objectIDs.isEmpty else { return }

        guard let state = transactions[transaction.id] else {
            Log.warning("Attempted to track display-name-only changes for unknown transaction \(transaction.id)", category: .sync)
            return
        }

        switch state {
        case .active(var modifications):
            modifications.displayNameOnlyIDs.formUnion(objectIDs)
            transactions[transaction.id] = .active(modifications)
        case .committed:
            Log.warning("Attempted to track display-name-only changes on committed transaction \(transaction.id)", category: .sync)
        }
    }

    // MARK: - Debug / Testing

    func reset() {
        transactions.removeAll()
    }

    var modifiedCount: Int {
        transactions.values.reduce(0) { $0 + $1.modifications.trackedCount }
    }

    func modificationCount(in transaction: Transaction) -> Int {
        transactions[transaction.id]?.modifications.trackedCount ?? 0
    }

    var transactionCount: Int {
        transactions.count
    }
}
