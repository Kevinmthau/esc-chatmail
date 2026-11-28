import Foundation

/// What the banner's Retry did (`ExhaustedSyncMessagesManaging.retryUndownloadableMessages`).
enum ExhaustedSyncMessagesRetryOutcome: Sendable, Equatable {
    /// Rows were given back to the drain and saved: a sync should run.
    case gaveBack
    /// The ledger was read and held nothing the banner counts.
    case nothingToGiveBack
    /// Nothing was written: no account work admitted, an unreadable ledger, a
    /// lease ended by an account transition, or a failed save. The banner
    /// comes back.
    case failed
}

/// The slice of `SyncFailureTracker` the conversation list's banner for mail
/// sync could not download needs, so its model can be tested without a store.
/// The banner counts exhausted rows and stalled ones
/// (`AbandonedSyncMessage.undownloadablePredicate(now:)`).
protocol ExhaustedSyncMessagesManaging: Sendable {
    /// The Gmail IDs of the rows the banner counts, oldest first, read under
    /// the account-work lease. nil while no account work is admitted or when
    /// the ledger cannot be read: never an empty answer for either.
    func fetchUndownloadableMessageIds() async -> [String]?
    /// Gives every row the banner counts its retries back, under the
    /// account-work lease, so the next sync's drain tries them again.
    func retryUndownloadableMessages() async -> ExhaustedSyncMessagesRetryOutcome
}

extension SyncFailureTracker: ExhaustedSyncMessagesManaging {}
