import Foundation

/// The slice of `SyncFailureTracker` the conversation list's banner for mail
/// sync gave up on needs, so its model can be tested without a store.
protocol ExhaustedSyncMessagesManaging: Sendable {
    /// The Gmail IDs of the rows the drain gave up on, oldest first, read
    /// under the account-work lease. nil while no account work is admitted or
    /// when the ledger cannot be read: never an empty answer for either.
    func fetchExhaustedMessageIds() async -> [String]?
    /// Gives every row the drain gave up on its retries back, under the
    /// account-work lease, so the next sync's drain tries them again.
    /// - Returns: whether any row was given back.
    func retryExhaustedMessages() async -> Bool
}

extension SyncFailureTracker: ExhaustedSyncMessagesManaging {}
