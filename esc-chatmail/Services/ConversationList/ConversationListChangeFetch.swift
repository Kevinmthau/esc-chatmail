import Foundation
import CoreData

/// The fetches the conversation list's change observation makes on its observed context
/// (`ConversationListViewModel+ChangeObservation`), built in one place so they share the
/// materialization the snapshot build needs and so `ScaleQueryPlanTests` can ask SQLite
/// about the requests the app makes.
enum ConversationListChangeFetch {
    /// Conversations matching `predicate`, materialized with the participant → person chain
    /// the snapshot build walks.
    ///
    /// Prefetching pulls that chain in the same round trip, rather than firing one to-many
    /// fault per row on the main queue. `returnsObjectsAsFaults = false` materializes each
    /// row at fetch time: a returned fault would leave a window before the snapshot build
    /// fires it, and a sibling delete landing in that window tombstones the row
    /// (`shouldDeleteInaccessibleFaults` defaults on), whose nil `id` the list item then
    /// refuses (`ConversationListItem.init?(conversation:)`); it trapped before that.
    /// `shouldRefreshRefetchedObjects` stays default: forcing a refresh would fight the
    /// automerge's registered-object merge.
    static func materializedConversations(
        matching predicate: NSPredicate,
        includesPendingChanges: Bool
    ) -> NSFetchRequest<Conversation> {
        let request = NSFetchRequest<Conversation>(entityName: "Conversation")
        request.predicate = predicate
        request.relationshipKeyPathsForPrefetching = ["participants", "participants.person"]
        request.includesPendingChanges = includesPendingChanges
        request.returnsObjectsAsFaults = false
        return request
    }

    /// The conversations a sibling context's save inserted or updated. Pending changes are
    /// included, so an unsaved edit the observed context holds still decides the row.
    static func savedConversations(withIDs objectIDs: Set<NSManagedObjectID>) -> NSFetchRequest<Conversation> {
        materializedConversations(
            matching: NSPredicate(format: "self IN %@", Array(objectIDs)),
            includesPendingChanges: true
        )
    }

    /// Stored window rows by objectID, for the Person fan-out bounded by the window
    /// (architecture review 2026-11, conversation-list-ui#4, contacts-person#6,
    /// gap-message-shape-extremes#5): the caller passes only the rows whose snapshots
    /// show a changed Person's address, so the store is asked for no participant at all.
    /// The review's `ANY participants.person IN %@` term made SQLite start from the
    /// participant table's person index, which for the user's own Person on the S2 store
    /// read all 12,000 of its participant rows with or without statistics (measured
    /// 2026-11-28, `ScaleQueryPlanTests`); by key the read is the window's rows and their
    /// participants.
    ///
    /// `objectIDs` must hold no temporary ID and no row with unsaved changes in the
    /// observed context, because the store knows nothing of either; the caller takes those
    /// from the context. So pending changes are not included, which would ask the store's
    /// answer to be patched with them for nothing.
    static func storedWindowConversations(withIDs objectIDs: [NSManagedObjectID]) -> NSFetchRequest<Conversation> {
        materializedConversations(
            matching: NSPredicate(format: "self IN %@", objectIDs),
            includesPendingChanges: false
        )
    }
}
