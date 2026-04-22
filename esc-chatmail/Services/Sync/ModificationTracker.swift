import Foundation
import CoreData

/// Tracks modified conversation IDs per sync run so rollup work is isolated
/// until the run that made the changes is ready to consume them.
actor ModificationTracker {
    struct Transaction: Sendable, Hashable {
        fileprivate let id: UUID
    }

    private enum TransactionState {
        case active(Set<NSManagedObjectID>)
        case committed(Set<NSManagedObjectID>)

        var modifications: Set<NSManagedObjectID> {
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
        transactions[transaction.id] = .active([])
        Log.debug("Started modification transaction: \(transaction.id)", category: .sync)
        return transaction
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
                "Committed modification transaction \(transaction.id) with \(modifications.count) conversations",
                category: .sync
            )
            return modifications
        case .committed(let modifications):
            Log.warning("Transaction \(transaction.id) was already committed", category: .sync)
            return modifications
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
                "Consumed committed transaction \(transaction.id) with \(modifications.count) conversations",
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
                "Rolled back modification transaction \(transaction.id) with \(modifications.count) conversations",
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
            modifications.insert(objectID)
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
            modifications.formUnion(objectIDs)
            transactions[transaction.id] = .active(modifications)
        case .committed:
            Log.warning("Attempted to track modifications on committed transaction \(transaction.id)", category: .sync)
        }
    }

    // MARK: - Debug / Testing

    func reset() {
        transactions.removeAll()
    }

    var modifiedCount: Int {
        transactions.values.reduce(0) { $0 + $1.modifications.count }
    }

    func modificationCount(in transaction: Transaction) -> Int {
        transactions[transaction.id]?.modifications.count ?? 0
    }

    var transactionCount: Int {
        transactions.count
    }
}
