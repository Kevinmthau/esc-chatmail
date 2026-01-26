import Foundation
import CoreData

/// Single source of truth for tracking modified conversations during sync.
///
/// This actor consolidates modification tracking that was previously duplicated
/// across MessagePersister and HistoryProcessor, eliminating race condition risks
/// and ensuring all modified conversations are captured for rollup updates.
///
/// ## Transaction Safety
/// The tracker supports transactional modification tracking to prevent data loss
/// when sync fails after modifications have been tracked but before rollup updates:
///
/// ```swift
/// let txId = await ModificationTracker.shared.beginTransaction()
/// // ... sync operations that track modifications ...
/// if syncSucceeded {
///     let modifications = await ModificationTracker.shared.commitTransaction(txId)
///     // ... perform rollup updates ...
/// } else {
///     await ModificationTracker.shared.rollbackTransaction(txId)
///     // Modifications are discarded, will be re-discovered on next sync
/// }
/// ```
actor ModificationTracker {

    /// Shared instance for use across sync components
    static let shared = ModificationTracker()

    // MARK: - Transaction Support

    /// Represents an active sync transaction
    private struct SyncTransaction {
        let id: UUID
        var modifications: Set<NSManagedObjectID>
    }

    /// Currently active transaction (if any)
    private var activeTransaction: SyncTransaction?

    /// Modifications tracked outside of a transaction (legacy support)
    private var pendingModifications: Set<NSManagedObjectID> = []

    private init() {}

    // MARK: - Transaction Management

    /// Begins a new sync transaction. All modifications tracked while the transaction
    /// is active will be associated with this transaction.
    /// - Returns: Transaction ID for use with commit/rollback, or existing transaction ID if one is active
    /// - Note: If a transaction is already active, returns the existing transaction ID
    ///         to prevent data loss from accidentally creating overlapping transactions
    func beginTransaction() -> UUID {
        // If there's an existing transaction, return its ID to prevent data loss
        // The caller should complete the existing transaction before starting a new one
        if let existingTx = activeTransaction {
            Log.warning("Transaction already active (id: \(existingTx.id)) - returning existing instead of creating new", category: .sync)
            return existingTx.id
        }

        let txId = UUID()
        activeTransaction = SyncTransaction(id: txId, modifications: [])
        Log.debug("Started new transaction: \(txId)", category: .sync)
        return txId
    }

    /// Commits a transaction and returns its modifications.
    /// - Parameter txId: The transaction ID returned from beginTransaction()
    /// - Returns: Set of modified conversation ObjectIDs from this transaction
    func commitTransaction(_ txId: UUID) -> Set<NSManagedObjectID> {
        guard let tx = activeTransaction else {
            Log.warning("Attempted to commit transaction \(txId) but no active transaction exists", category: .sync)
            return []
        }

        guard tx.id == txId else {
            Log.warning("Transaction ID mismatch: attempting to commit \(txId) but active transaction is \(tx.id)", category: .sync)
            return []
        }

        let result = tx.modifications
        activeTransaction = nil
        Log.debug("Committed transaction \(txId) with \(result.count) modifications", category: .sync)
        return result
    }

    /// Rolls back a transaction, discarding its modifications.
    /// Modifications will be re-discovered on the next sync.
    /// - Parameter txId: The transaction ID returned from beginTransaction()
    func rollbackTransaction(_ txId: UUID) {
        guard let tx = activeTransaction, tx.id == txId else {
            Log.warning("Attempted to rollback unknown or already-committed transaction", category: .sync)
            return
        }

        Log.debug("Rolling back transaction with \(tx.modifications.count) modifications", category: .sync)
        activeTransaction = nil
        // Modifications are intentionally discarded - they'll be re-discovered on next sync
    }

    /// Returns true if there's an active transaction
    var hasActiveTransaction: Bool {
        activeTransaction != nil
    }

    // MARK: - Tracking

    /// Tracks a conversation as modified by its objectID.
    /// If a transaction is active, the modification is tracked within that transaction.
    func trackModifiedConversation(_ objectID: NSManagedObjectID) {
        if activeTransaction != nil {
            activeTransaction?.modifications.insert(objectID)
        } else {
            pendingModifications.insert(objectID)
        }
    }

    /// Tracks multiple conversations as modified
    func trackModifiedConversations(_ objectIDs: [NSManagedObjectID]) {
        for objectID in objectIDs {
            trackModifiedConversation(objectID)
        }
    }

    /// Tracks multiple conversations as modified from a Set
    func trackModifiedConversations(_ objectIDs: Set<NSManagedObjectID>) {
        if activeTransaction != nil {
            activeTransaction?.modifications.formUnion(objectIDs)
        } else {
            pendingModifications.formUnion(objectIDs)
        }
    }

    // MARK: - Retrieval (Legacy API)

    /// Returns and clears the set of modified conversation IDs.
    /// Call this after sync completes to get all modifications for rollup updates.
    ///
    /// Note: For new code, prefer using transaction-based tracking with
    /// beginTransaction/commitTransaction for better error recovery.
    ///
    /// - Warning: If an active transaction exists, this will clear it and log a warning.
    ///            Use commitTransaction() instead if you have an active transaction.
    func getAndClearModifiedConversations() -> Set<NSManagedObjectID> {
        // Include both pending modifications and any active transaction modifications
        var result = pendingModifications

        if let tx = activeTransaction {
            // Warn about clearing an active transaction - this could indicate a bug
            // where sync failed but didn't properly rollback the transaction
            Log.warning("getAndClearModifiedConversations called with active transaction (id: \(tx.id), \(tx.modifications.count) modifications) - this may indicate improper transaction handling", category: .sync)
            result.formUnion(tx.modifications)
            activeTransaction = nil
        }

        pendingModifications.removeAll()
        return result
    }

    /// Resets the tracker - call at start of sync
    func reset() {
        pendingModifications.removeAll()
        activeTransaction = nil
    }

    /// Returns the current count of tracked modifications (for debugging)
    var modifiedCount: Int {
        let txCount = activeTransaction?.modifications.count ?? 0
        return pendingModifications.count + txCount
    }
}
