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
            noteWindowInvalidated()
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
            // performAndWait executes on the calling thread — main, per the
            // .receive(on:) above — while holding the context's queue, so
            // this is main-actor work serialized against merge blocks and
            // the objectsDidChange sink that fires inside them.
            MainActor.assumeIsolated {
                applyConversationChanges(
                    updatedConversations: conversationsToApply(
                        savedIDs: insertedIDs.union(updatedIDs),
                        in: context
                    ),
                    deletedIDs: deletedIDs
                )
            }
        }
    }

    /// The saved conversations the list must apply, read in two steps so that the
    /// rows a save touches past the window cost no participant read on the main
    /// thread.
    ///
    /// First every changed row, materialized without its participants, which is
    /// enough for `ConversationListStore.admittance`: archived, sort key, and whether
    /// the window holds it. Then the participant prefetch for the admitted rows alone,
    /// which the snapshot build needs. A row the window holds that the change takes
    /// out goes to the store from the first read, which removes it without reading
    /// anything more. Until 2026-11-28 every changed row was fetched with its
    /// participants and persons and snapshotted before the trim dropped the ones past
    /// the window: up to a page of 500 rows per save of a catch-up sync
    /// (architecture review 2026-11, conversation-list-ui#5).
    ///
    /// Both reads include pending changes, so an unsaved edit this context holds (an
    /// optimistic send's new `lastMessageDate`) still decides a row's place. Rows a
    /// later save already deleted simply do not return — the same drop existingObject's
    /// throw produced; the delete's own notification removes the row.
    private func conversationsToApply(
        savedIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext
    ) -> [Conversation] {
        guard !savedIDs.isEmpty else { return [] }

        let changedRows: [Conversation]
        do {
            changedRows = try context.fetch(
                ConversationListChangeFetch.savedConversationsForAdmission(withIDs: savedIDs)
            )
        } catch {
            Log.error("Failed to fetch sibling-save conversations", category: .conversation, error: error)
            return []
        }

        var toApply: [Conversation] = []
        var admittedIDs = Set<NSManagedObjectID>()
        for row in changedRows {
            switch listStore.admittance(of: row, isSourceConversation: isSourceConversation(_:)) {
            case .admitted:
                admittedIDs.insert(row.objectID)
            case .leaves:
                toApply.append(row)
            case .outside:
                continue
            }
        }
        guard !admittedIDs.isEmpty else { return toApply }

        do {
            toApply += try context.fetch(ConversationListChangeFetch.savedConversations(withIDs: admittedIDs))
        } catch {
            Log.error("Failed to fetch sibling-save conversations", category: .conversation, error: error)
        }
        return toApply
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

    /// The window's conversations whose rows a merged Person change can alter, read on
    /// the observed context and bounded by the window.
    ///
    /// Until 2026-11-28 this walked each updated or refreshed Person's
    /// `conversationParticipations` and returned every conversation the person ever
    /// joined, archived rows and rows past the window included, each faulted and
    /// snapshotted one at a time on the main thread before the trim dropped it: a few
    /// thousand faults for a person in a few hundred conversations, for every merged save
    /// that touched that Person (architecture review 2026-11, conversation-list-ui#4,
    /// contacts-person#6, gap-message-shape-extremes#5, and the list half of
    /// gap-change-propagation-pipeline#1).
    ///
    /// Now the window's own snapshots answer it. A Person whose change no row can show is
    /// dropped (`ConversationListPersonChangePolicy`), with nothing fetched or faulted, and
    /// the rows a change can reach are the ones whose snapshots show its address: every row
    /// the Person is in shows it, and a row showing it through a duplicate Person is
    /// snapshotted again for nothing. A Person change cannot bring a row into the window:
    /// it changes no sort key, search reads only the conversation, and the contact filters
    /// read the address, which no Person writer changes. Rows with unsaved changes in the
    /// context (an optimistic send's conversation, which may hold a permanent ID before any
    /// save) are taken from the context, because the store knows nothing of them; the
    /// stored rest cost one fetch by key.
    private func conversationsAffectedByPersonChanges(in notification: Notification) -> [Conversation] {
        guard let context = observedConversationContext else { return [] }
        let persons = contextObjects(
            forKeys: [NSUpdatedObjectsKey, NSRefreshedObjectsKey],
            in: notification
        )
        .compactMap { $0 as? Person }
        let window = listStore.visibleItems
        guard !persons.isEmpty, !window.isEmpty else { return [] }

        // KVC, not `person.email`: a non-optional attribute traps on a tombstone, and a
        // Person read here must cost one row fault at most.
        let personEmails = persons.map { person in
            (person, EmailNormalizer.normalize(person.value(forKey: "email") as? String ?? ""))
        }
        let shownNames = ConversationListPersonChangePolicy.shownDisplayNamesByEmail(
            in: window.map(\.snapshot.participantDisplayNames),
            forEmails: Set(personEmails.map { $0.1 })
        )
        let changedEmails = Set(personEmails.compactMap { person, normalizedEmail in
            ConversationListPersonChangePolicy.mayChangeWindowRows(
                normalizedEmail: normalizedEmail,
                displayName: person.displayName,
                shownDisplayNamesByEmail: shownNames
            ) ? normalizedEmail : nil
        })
        guard !changedEmails.isEmpty else { return [] }

        var affected: [Conversation] = []
        var storedIDs: [NSManagedObjectID] = []
        for item in window
        where item.snapshot.participantDisplayNames.contains(where: { changedEmails.contains($0.email) }) {
            // An unsaved row always has changes, whatever its ID: an optimistic send gives
            // its conversation a permanent ID before the list first sees it.
            if let registered = context.registeredObject(for: item.id) as? Conversation,
               registered.hasChanges {
                // A pending delete is the deletion's own notification's to remove.
                if !registered.isDeleted {
                    affected.append(registered)
                }
            } else if !item.id.isTemporaryID {
                storedIDs.append(item.id)
            }
        }

        if !storedIDs.isEmpty {
            do {
                affected += try context.fetch(
                    ConversationListChangeFetch.storedWindowConversations(withIDs: storedIDs)
                )
            } catch {
                // Nothing to undo: the rows keep the snapshots they have, which is what a
                // Person change that reached no row leaves too.
                Log.error("Failed to fetch the window rows a Person change names", category: .conversation, error: error)
            }
        }
        return affected
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
