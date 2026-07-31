import Foundation
import CoreData

/// Durable ledger of messages the sync pipeline could not complete.
/// `gmailMessageId` carries a uniqueness constraint from birth, making writes
/// natural upserts under the object-trump merge policy.
///
/// Rows are staged into the sync run's own context by `SyncFailureTracker`
/// and commit with the run's final save — atomically with the history cursor.
///
/// `nextRetryAt` is reserved for drain retry pacing (resumable-executor work)
/// and has no consumers yet.
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
    }

    /// Why the message entered the ledger (coarse blocking-failure buckets).
    enum FailureClass: String {
        /// The Gmail fetch failed (transient-exhausted or non-retriable).
        case fetchFailed = "fetchFailed"
        /// Fetched but the local persistence pass reported it failed.
        case persistenceFailed = "persistenceFailed"
    }
}
