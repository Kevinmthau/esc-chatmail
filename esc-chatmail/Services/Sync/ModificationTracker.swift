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

        static let empty = ConversationModifications(
            rollupIDs: [],
            claimedRollupIDs: [],
            displayNameOnlyIDs: []
        )

        var trackedCount: Int {
            rollupIDs.union(claimedRollupIDs).count + displayNameOnlyIDs.count
        }
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
            let claimed = modifications.rollupIDs
            guard !claimed.isEmpty else { return [] }
            modifications.claimedRollupIDs.formUnion(claimed)
            modifications.rollupIDs = []
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

    /// Returns conversations that only need display-name refreshes.
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
