import Foundation
import CoreData

/// Durable mid-run sync progress, introduced in model v3 for the resumable
/// executor (roadmap Phase 3). One row per checkpoint kind — `kind` carries a
/// uniqueness constraint (new v3 entity, so it may carry constraints from
/// birth), making writes natural upserts under the object-trump merge policy.
///
/// `accountEmail` is the single-account validation tag (the
/// `BackgroundSyncContinuationState.isCompatible` pattern): consumers must
/// discard a checkpoint whose accountEmail doesn't match the signed-in
/// account rather than resume another account's state.
///
/// Note: the constraint is on `kind` ALONE, so a write for one account
/// replaces another account's row of the same kind. Correct while the app is
/// single-account; if multi-account ever lands, the constraint must become
/// (`kind`, `accountEmail`) in a NEW model version — never by editing v3.
extension SyncCheckpoint {
    @NSManaged public var id: UUID
    @NSManaged public var accountEmail: String
    @NSManaged public var kind: String
    @NSManaged public var startHistoryId: String?
    @NSManaged public var pageToken: String?
    @NSManaged public var pendingMessageIdsJSON: String?
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date

    @nonobjc public class func fetchRequest() -> NSFetchRequest<SyncCheckpoint> {
        return NSFetchRequest<SyncCheckpoint>(entityName: "SyncCheckpoint")
    }
}
