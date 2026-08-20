import Foundation
import CoreData
import Combine

/// Core Data change-observation pipeline for `ConversationListViewModel`:
/// the objectsDidChange / didSaveObjectIDs subscriptions, both change
/// handlers, the nonisolated relevance guards, and the notification-payload
/// helper family. The subscription storage (`observedConversationContext`,
/// both cancellables) lives in the base file because extensions cannot hold
/// stored properties; the base file's header enumerates the full split.
extension ConversationListViewModel {
    // MARK: - Subscriptions

    /// Internal (not private) because `onAppear(in:)` in the base file drives
    /// it; every other entry into the pipeline stays private to this file.
    func startObservingConversationChanges(in context: NSManagedObjectContext) {
        guard observedConversationContext !== context
                || conversationChangesCancellable == nil
                || conversationSavesCancellable == nil else {
            return
        }

        conversationChangesCancellable?.cancel()
        conversationSavesCancellable?.cancel()
        observedConversationContext = context
        conversationChangesCancellable = NotificationCenter.default.publisher(
            for: .NSManagedObjectContextObjectsDidChange,
            object: context
        )
        .sink { [weak self] notification in
            self?.handleConversationContextChange(notification)
        }

        // Registration-independent delivery for sibling-context saves. The
        // automerge into the observed context only *refreshes* objects still
        // registered there, and this list holds objectIDs + value snapshots,
        // never the managed objects — so a background rollup save for a
        // conversation whose object has deallocated (or that sits outside the
        // loaded window) can produce no Conversation in objectsDidChange,
        // leaving the row stale until relaunch. didSaveObjectIDs is posted by
        // every saving context and carries only thread-safe NSManagedObjectIDs.
        let coordinator = context.persistentStoreCoordinator
        conversationSavesCancellable = NotificationCenter.default.publisher(
            for: NSManagedObjectContext.didSaveObjectIDsNotification
        )
        .filter { [weak context] notification in
            // Runs on the saving context's thread; objectID entity checks only,
            // nothing faults. The coordinator check scopes delivery to our
            // store, and the identity check skips the observed context's own
            // saves, which already flowed through objectsDidChange.
            guard let context,
                  let sourceContext = notification.object as? NSManagedObjectContext,
                  sourceContext !== context,
                  sourceContext.persistentStoreCoordinator === coordinator else {
                return false
            }
            return Self.isRelevantConversationSave(notification.userInfo)
        }
        .receive(on: DispatchQueue.main)
        .sink { [weak self] notification in
            self?.handleSiblingContextSave(notification)
        }
    }

    // MARK: - Live Change Handling

    private func handleConversationContextChange(_ notification: Notification) {
        guard notification.userInfo?[NSInvalidatedAllObjectsKey] == nil else {
            listStore.removeAll()
            // The wholesale invalidation empties the window; whatever fills it
            // next is a fresh window generation and must prefetch again.
            prefetchedPersonEmails.removeAll()
            publishVisibleItems()
            return
        }

        // objectsDidChange fires for every merged sync save; most merges carry
        // only Message/Attachment/Label churn the list doesn't render, yet the
        // passes below re-scan every changed set. Bail out early unless the
        // change can actually affect the list.
        guard Self.isRelevantConversationListChange(notification.userInfo) else {
            return
        }

        let inserted = conversationObjects(forKey: NSInsertedObjectsKey, in: notification)
        let updated = conversationObjects(forKey: NSUpdatedObjectsKey, in: notification)
        let refreshed = conversationObjects(forKey: NSRefreshedObjectsKey, in: notification)
        let personAffected = conversationsAffectedByPersonChanges(in: notification)
        let invalidatedIDs = conversationObjectIDs(forKey: NSInvalidatedObjectsKey, in: notification)
        let deletedIDs = conversationObjectIDs(forKey: NSDeletedObjectsKey, in: notification)
        let updatedConversations = uniqueConversations(from: inserted + updated + refreshed + personAffected)
        let removedIDs = deletedIDs.union(invalidatedIDs)

        applyConversationChanges(updatedConversations: updatedConversations, deletedIDs: removedIDs)
    }

    // MARK: - Relevance Guards

    /// Single-pass early-return relevance scan for objectsDidChange payloads:
    /// relevant when any Conversation appears in {inserted, updated,
    /// refreshed, deleted, invalidated} or any Person in {updated, refreshed}
    /// (display-name enrichment). The refreshed set is mandatory — merged
    /// background rollup updates surface as Conversation *refreshes*, so
    /// omitting it would break live list updates. Type checks only; nothing
    /// here faults an object.
    nonisolated static func isRelevantConversationListChange(_ userInfo: [AnyHashable: Any]?) -> Bool {
        guard let userInfo else { return false }

        let keys = [
            NSInsertedObjectsKey,
            NSUpdatedObjectsKey,
            NSRefreshedObjectsKey,
            NSDeletedObjectsKey,
            NSInvalidatedObjectsKey
        ]
        let personKeys: Set<String> = [NSUpdatedObjectsKey, NSRefreshedObjectsKey]

        for key in keys {
            guard let objects = userInfo[key] as? Set<NSManagedObject> else { continue }
            let includesPersons = personKeys.contains(key)
            for object in objects {
                if object is Conversation {
                    return true
                }
                if includesPersons, object is Person {
                    return true
                }
            }
        }
        return false
    }

    /// Save-notification analog of `isRelevantConversationListChange`:
    /// relevant when any inserted/updated/deleted objectID is a Conversation.
    /// Most saves carry only Message/Attachment/Label churn; this gate runs on
    /// the saving context's thread so those never cost a main-queue hop.
    /// ObjectID entity checks only; nothing here faults an object.
    nonisolated static func isRelevantConversationSave(_ userInfo: [AnyHashable: Any]?) -> Bool {
        guard let userInfo else { return false }

        for key in [NSInsertedObjectIDsKey, NSUpdatedObjectIDsKey, NSDeletedObjectIDsKey] {
            guard let objectIDs = userInfo[key] as? Set<NSManagedObjectID> else { continue }
            if objectIDs.contains(where: { $0.entity.name == "Conversation" }) {
                return true
            }
        }
        return false
    }

    // MARK: - Sibling-Save Handling

    /// Applies a sibling context's saved Conversation changes to the list.
    ///
    /// Runs on the main queue. On the production viewContext (a main-queue
    /// context) the `performAndWait` executes inline — identical to a direct
    /// call. On a private-queue observed context (test stacks) it serializes
    /// this pipeline with the automerge's merge blocks and the
    /// objectsDidChange sink that fires inside them, so neither the context
    /// nor the list store is ever touched from two threads at once.
    /// Whichever pipeline lands first, the batch fetch reads the saved
    /// rows (materialized fresh from the store or refreshed by the merge),
    /// and a duplicate pass rebuilds identical snapshots that
    /// `publishVisibleItems`'s equality guard suppresses.
    private func handleSiblingContextSave(_ notification: Notification) {
        guard let context = observedConversationContext else { return }

        let insertedIDs = conversationSaveObjectIDs(forKey: NSInsertedObjectIDsKey, in: notification)
        let updatedIDs = conversationSaveObjectIDs(forKey: NSUpdatedObjectIDsKey, in: notification)
        let deletedIDs = conversationSaveObjectIDs(forKey: NSDeletedObjectIDsKey, in: notification)

        context.performAndWait {
            // One batch fetch instead of a per-ID existingObject(with:) loop:
            // prefetching pulls the participants → person chain the snapshot
            // build walks in the same round trip, rather than firing one
            // to-many fault per row on the main queue. Rows a later save
            // already deleted simply do not return — the same drop
            // existingObject's throw produced; the delete's own notification
            // removes the row.
            let changedIDs = insertedIDs.union(updatedIDs)
            var updatedConversations: [Conversation] = []
            if !changedIDs.isEmpty {
                let request = NSFetchRequest<Conversation>(entityName: "Conversation")
                request.predicate = NSPredicate(format: "self IN %@", Array(changedIDs))
                request.relationshipKeyPathsForPrefetching = ["participants", "participants.person"]
                request.includesPendingChanges = true
                // Materialize at fetch time, like existingObject did. Returned
                // faults would leave a window before the snapshot build fires
                // them, and a sibling delete landing in that window tombstones
                // the row (shouldDeleteInaccessibleFaults defaults on) — the
                // snapshot build then crashes reading its nil `id` UUID.
                request.returnsObjectsAsFaults = false
                // shouldRefreshRefetchedObjects stays default — forcing a
                // refresh here would fight the automerge's registered-object
                // merge ("whichever pipeline lands first" above).
                do {
                    updatedConversations = try context.fetch(request)
                } catch {
                    Log.error("Failed to fetch sibling-save conversations", category: .conversation, error: error)
                }
            }

            // performAndWait executes on the calling thread — main, per the
            // .receive(on:) above — while holding the context's queue, so
            // this is main-actor work serialized against merge blocks and
            // the objectsDidChange sink that fires inside them.
            MainActor.assumeIsolated {
                applyConversationChanges(
                    updatedConversations: updatedConversations,
                    deletedIDs: deletedIDs
                )
            }
        }
    }

    // MARK: - Notification Payload Helpers

    private func conversationSaveObjectIDs(forKey key: String, in notification: Notification) -> Set<NSManagedObjectID> {
        let objectIDs = notification.userInfo?[key] as? Set<NSManagedObjectID> ?? []
        return Set(objectIDs.filter { $0.entity.name == "Conversation" })
    }

    private func conversationObjects(forKey key: String, in notification: Notification) -> [Conversation] {
        let objects = notification.userInfo?[key] as? Set<NSManagedObject> ?? []
        return objects.compactMap { $0 as? Conversation }
    }

    private func conversationObjectIDs(forKey key: String, in notification: Notification) -> Set<NSManagedObjectID> {
        let objects = notification.userInfo?[key] as? Set<NSManagedObject> ?? []
        return Set(objects.compactMap { object in
            guard object is Conversation else { return nil }
            return object.objectID
        })
    }

    private func conversationsAffectedByPersonChanges(in notification: Notification) -> [Conversation] {
        contextObjects(
            forKeys: [NSUpdatedObjectsKey, NSRefreshedObjectsKey],
            in: notification
        )
        .compactMap { $0 as? Person }
        .flatMap { person in
            person.conversationParticipations?.compactMap(\.conversation) ?? []
        }
    }

    private func contextObjects(
        forKeys keys: [String],
        in notification: Notification
    ) -> Set<NSManagedObject> {
        keys.reduce(into: Set<NSManagedObject>()) { result, key in
            let objects = notification.userInfo?[key] as? Set<NSManagedObject> ?? []
            result.formUnion(objects)
        }
    }

    private func uniqueConversations(from conversations: [Conversation]) -> [Conversation] {
        var uniqueByID: [NSManagedObjectID: Conversation] = [:]

        for conversation in conversations {
            uniqueByID[conversation.objectID] = conversation
        }

        return Array(uniqueByID.values)
    }
}
