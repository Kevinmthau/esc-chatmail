import Foundation
import CoreData

/// Single source of truth for tracking modified conversations during sync.
///
/// This actor consolidates modification tracking that was previously duplicated
/// across MessagePersister and HistoryProcessor, eliminating race condition risks
/// and ensuring all modified conversations are captured for rollup updates.
actor ModificationTracker {

    /// Shared instance for use across sync components
    static let shared = ModificationTracker()

    /// Set of conversation ObjectIDs modified during current sync batch
    private var modifiedConversationIDs: Set<NSManagedObjectID> = []

    private init() {}

    // MARK: - Tracking

    /// Tracks a conversation as modified by its objectID
    func trackModifiedConversation(_ objectID: NSManagedObjectID) {
        modifiedConversationIDs.insert(objectID)
    }

    /// Tracks multiple conversations as modified
    func trackModifiedConversations(_ objectIDs: [NSManagedObjectID]) {
        for objectID in objectIDs {
            modifiedConversationIDs.insert(objectID)
        }
    }

    /// Tracks multiple conversations as modified from a Set
    func trackModifiedConversations(_ objectIDs: Set<NSManagedObjectID>) {
        modifiedConversationIDs.formUnion(objectIDs)
    }

    // MARK: - Retrieval

    /// Returns and clears the set of modified conversation IDs.
    /// Call this after sync completes to get all modifications for rollup updates.
    func getAndClearModifiedConversations() -> Set<NSManagedObjectID> {
        let result = modifiedConversationIDs
        modifiedConversationIDs.removeAll()
        return result
    }

    /// Resets the tracker - call at start of sync
    func reset() {
        modifiedConversationIDs.removeAll()
    }

    /// Returns the current count of tracked modifications (for debugging)
    var modifiedCount: Int {
        modifiedConversationIDs.count
    }
}
