import Foundation
import CoreData

/// Durable ledger of messages the sync pipeline could not complete.
/// `gmailMessageId` carries a uniqueness constraint from birth, making writes
/// natural upserts under the object-trump merge policy.
///
/// Rows are staged into the sync run's own context by `SyncFailureTracker`
/// and commit with the run's final save — atomically with the history cursor.
///
/// `nextRetryAt` paces the abandoned-message drain: `nil` (fresh
/// abandonments, deferred rows, legacy rows) is immediately eligible; a
/// failed drain attempt stamps an exponential backoff via
/// `SyncFailureTracker.stageAbandonedRetryOutcome`, enforced in the drain
/// predicate. Re-capturing a row as deferred clears it.
///
/// `retryCount` counts the drain's message-scoped failures only (a 4xx, an
/// undecodable or unprocessable payload, a failed persist). A timeout, a
/// network error, a 5xx or a 429 says nothing about the message and only
/// stamps the backoff.
extension AbandonedSyncMessage {
    @NSManaged public var id: UUID
    @NSManaged public var gmailMessageId: String
    @NSManaged public var abandonedAt: Date
    @NSManaged public var reason: String?
    @NSManaged public var retryCount: Int16
    @NSManaged public var state: String?
    @NSManaged public var failureClass: String?
    @NSManaged public var sourceHistoryId: String?
    @NSManaged public var nextRetryAt: Date?

    @nonobjc public class func fetchRequest() -> NSFetchRequest<AbandonedSyncMessage> {
        return NSFetchRequest<AbandonedSyncMessage>(entityName: "AbandonedSyncMessage")
    }

    /// Ledger lifecycle. A `nil` state on a row means `.abandoned` — every row
    /// written before the model v3 columns existed was created at abandonment.
    enum State: String {
        /// Still covered by the frozen cursor: the normal re-scan of the same
        /// history window retries it, so the abandoned-message drain skips it.
        case deferred = "deferred"
        /// The cursor advanced past it; only the drain can recover it.
        case abandoned = "abandoned"
        /// The drain gave up on it: `SyncConfig.maxAbandonedMessageRetries`
        /// message-scoped failures (`SyncFailureTracker.stageAbandonedRetryOutcome`).
        /// Kept with `retryCount` at the cap, never deleted, so the
        /// conversation list can say the message was not downloaded
        /// (architecture review 2026-11, sync-persist-path#6). The drain's
        /// `retryCount <` term excludes it, in earlier builds too, which read
        /// an unknown state as not deferred. It leaves the ledger when a
        /// Message with its ID is stored, or when the user's Retry gives it
        /// back to the drain. Find these rows with `exhaustedPredicate`, never
        /// by this state alone.
        case exhausted = "exhausted"
    }

    /// The rows the drain has given up on: `retryCount` at the cap and not
    /// deferred. Counted by the retry count, not by `state == exhausted`: a
    /// re-scan can make an exhausted row deferred again, and the escape hatch
    /// then abandoned, with its spent budget kept, so the drain never offers it
    /// either. A deferred row is the frozen cursor's to retry. The `state ==
    /// nil` disjunct is load-bearing on SQLite, where a legacy row has no state.
    static var exhaustedPredicate: NSPredicate {
        NSPredicate(
            format: "retryCount >= %d AND (state == nil OR state != %@)",
            SyncConfig.maxAbandonedMessageRetries,
            State.deferred.rawValue
        )
    }

    /// Why the message entered the ledger (coarse blocking-failure buckets).
    enum FailureClass: String {
        /// The Gmail fetch failed (transient-exhausted or non-retriable).
        case fetchFailed = "fetchFailed"
        /// Fetched but the local persistence pass reported it failed.
        case persistenceFailed = "persistenceFailed"
    }
}
