import Foundation
import CoreData

// MARK: - Empty Entity Cleanup

extension DataCleanupService {

    /// Removes conversations that have no messages, participants, or user state.
    /// Empty pinned/muted shells are archived and hidden instead.
    func removeEmptyConversations(in context: NSManagedObjectContext) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        await context.perform {
            do {
                let pendingSendConversationIDs = try self.pendingSendConversationIDs(in: context)
                let pendingActionConversationIDs = Set(
                    try PendingAction.referencesByConversationID(in: context).keys
                )
                let protectedConversationIDs = pendingSendConversationIDs
                    .union(pendingActionConversationIDs)
                let notProtected = protectedConversationIDs.isEmpty
                    ? NSPredicate(value: true)
                    : NSPredicate(
                        format: "NOT (id IN %@)",
                        Array(protectedConversationIDs) as NSArray
                    )

                // A crash-safe identity repair can leave an empty shell as the
                // only persisted owner of pin/mute state. Archive it through
                // the canonical empty rollup instead of exposing a ghost row
                // or batch-deleting user state.
                let statefulRequest = Conversation.fetchRequest()
                statefulRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    ConversationPredicates.empty,
                    NSPredicate(format: "pinned == YES OR muted == YES"),
                    notProtected
                ])
                let emptySnapshot = ConversationRollupSnapshot.make(from: [])
                for conversation in try context.fetch(statefulRequest) {
                    emptySnapshot.apply(to: conversation)
                }
                guard self.coreDataStack.saveIfNeeded(
                    context: context,
                    caller: "DataCleanupService.removeEmptyConversations.archiveStateful"
                ) else {
                    return
                }

                let request = NSFetchRequest<NSFetchRequestResult>(entityName: "Conversation")
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    ConversationPredicates.empty,
                    NSPredicate(format: "pinned == NO AND muted == NO"),
                    notProtected
                ])
                request.resultType = .managedObjectIDResultType
                guard let objectIDs = try context.fetch(request) as? [NSManagedObjectID],
                      !objectIDs.isEmpty else {
                    return
                }

                let batchDeleteRequest = NSBatchDeleteRequest(objectIDs: objectIDs)
                batchDeleteRequest.resultType = .resultTypeObjectIDs

                let result = try context.execute(batchDeleteRequest) as? NSBatchDeleteResult
                if let deletedIDs = result?.result as? [NSManagedObjectID] {
                    let changes = [NSDeletedObjectsKey: deletedIDs]
                    NSManagedObjectContext.mergeChanges(
                        fromRemoteContextSave: changes,
                        into: [self.coreDataStack.viewContext]
                    )

                    let duration = CFAbsoluteTimeGetCurrent() - startTime
                    Log.info("Removed \(deletedIDs.count) empty conversations in \(String(format: "%.3f", duration))s", category: .coreData)
                }
            } catch {
                Log.error("Failed to batch delete empty conversations", category: .coreData, error: error)
                self.removeEmptyConversationsFallback(in: context)
            }
        }
    }

    /// Fallback for removing empty conversations when batch delete fails.
    internal func removeEmptyConversationsFallback(in context: NSManagedObjectContext) {
        let protectedConversationIDs: Set<UUID>
        do {
            let pendingSendConversationIDs = try self.pendingSendConversationIDs(in: context)
            let pendingActionConversationIDs = Set(
                try PendingAction.referencesByConversationID(in: context).keys
            )
            protectedConversationIDs = pendingSendConversationIDs
                .union(pendingActionConversationIDs)
        } catch {
            Log.error(
                "Failed to fetch protected references before fallback empty conversation cleanup",
                category: .coreData,
                error: error
            )
            return
        }

        let request = Conversation.fetchRequest()
        request.fetchBatchSize = 50

        guard let conversations = try? context.fetch(request) else { return }

        var removedCount = 0
        var archivedCount = 0
        let emptySnapshot = ConversationRollupSnapshot.make(from: [])
        for conversation in conversations where !protectedConversationIDs.contains(conversation.id) {
            let hasParticipants = (conversation.participants?.count ?? 0) > 0
            let hasMessages = (conversation.messages?.count ?? 0) > 0

            if !hasParticipants && !hasMessages {
                if conversation.pinned || conversation.muted {
                    emptySnapshot.apply(to: conversation)
                    archivedCount += 1
                } else {
                    context.delete(conversation)
                    removedCount += 1
                }
            }
        }

        if removedCount > 0 || archivedCount > 0 {
            Log.info(
                "Cleaned empty conversations (fallback): removed \(removedCount), archived \(archivedCount) stateful",
                category: .coreData
            )
            coreDataStack.saveIfNeeded(context: context)
        }
    }

    /// Removes all draft messages from the database.
    func removeDraftMessages(in context: NSManagedObjectContext) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        await context.perform {
            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
            fetchRequest.predicate = MessagePredicates.drafts

            let batchDeleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
            batchDeleteRequest.resultType = .resultTypeObjectIDs

            do {
                let result = try context.execute(batchDeleteRequest) as? NSBatchDeleteResult
                let deletedIDs = result?.result as? [NSManagedObjectID] ?? []
                let deletedCount = deletedIDs.count

                if deletedCount > 0 {
                    let changes = [NSDeletedObjectsKey: deletedIDs]
                    NSManagedObjectContext.mergeChanges(
                        fromRemoteContextSave: changes,
                        into: [self.coreDataStack.viewContext, context]
                    )

                    let duration = CFAbsoluteTimeGetCurrent() - startTime
                    Log.info("Removed \(deletedCount) draft messages in \(String(format: "%.3f", duration))s", category: .coreData)
                }
            } catch {
                Log.error("Failed to batch delete draft messages", category: .coreData, error: error)
                self.removeDraftMessagesFallback(in: context)
            }
        }
    }

    /// Fallback for removing draft messages when batch delete fails.
    internal func removeDraftMessagesFallback(in context: NSManagedObjectContext) {
        let request = Message.fetchRequest()
        request.predicate = MessagePredicates.drafts
        request.fetchBatchSize = 50

        guard let draftMessages = try? context.fetch(request) else { return }

        var removedCount = 0
        for message in draftMessages {
            context.delete(message)
            removedCount += 1
        }

        if removedCount > 0 {
            Log.info("Removed \(removedCount) draft messages (fallback)", category: .coreData)
            coreDataStack.saveIfNeeded(context: context)
        }
    }

    // MARK: - Orphaned Data Cleanup

    /// Detaches PendingActions whose metadata-only conversation has been
    /// deleted. Their message ID or payload remains the executable target, so
    /// deleting the action here would silently discard a queued user command.
    func removeOrphanedPendingActions(in context: NSManagedObjectContext) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        await context.perform {
            let request = PendingAction.fetchRequest()
            request.fetchBatchSize = 100

            do {
                let actions = try context.fetch(request)

                // Collect all conversation IDs that need to be checked
                let conversationIds = Set(actions.compactMap { $0.conversationId })
                guard !conversationIds.isEmpty else { return }

                // Single batch fetch to find which conversations exist
                let existingRequest = NSFetchRequest<NSDictionary>(entityName: "Conversation")
                existingRequest.predicate = NSPredicate(format: "id IN %@", conversationIds as CVarArg)
                existingRequest.propertiesToFetch = ["id"]
                existingRequest.resultType = .dictionaryResultType
                let existingResults = try context.fetch(existingRequest)
                let existingIds = Set(existingResults.compactMap { $0["id"] as? UUID })

                // Detach actions whose conversation no longer exists. This is
                // the race-safe backstop when an action is enqueued after a
                // destructive cleanup pass captured its retargeting map.
                var detachedCount = 0
                for action in actions {
                    if let conversationId = action.conversationId, !existingIds.contains(conversationId) {
                        Log.debug("Detaching pending action from deleted conversation: \(conversationId)", category: .coreData)
                        action.conversationId = nil
                        detachedCount += 1
                    }
                }

                if detachedCount > 0 {
                    try context.save()
                    let duration = CFAbsoluteTimeGetCurrent() - startTime
                    Log.info("Detached \(detachedCount) pending actions from deleted conversations in \(String(format: "%.3f", duration))s", category: .coreData)
                }
            } catch {
                Log.error("Failed to cleanup orphaned pending actions", category: .coreData, error: error)
            }
        }
    }

    /// Removes orphaned ConversationParticipant entries that reference non-existent conversations.
    func removeOrphanedConversationParticipants(in context: NSManagedObjectContext) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        await context.perform {
            // Use batch delete for efficiency - find participants where conversation is nil
            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "ConversationParticipant")
            fetchRequest.predicate = NSPredicate(format: "conversation == nil")
            fetchRequest.resultType = .managedObjectIDResultType

            do {
                guard let objectIDs = try context.fetch(fetchRequest) as? [NSManagedObjectID],
                      !objectIDs.isEmpty else {
                    return
                }

                let batchDeleteRequest = NSBatchDeleteRequest(objectIDs: objectIDs)
                batchDeleteRequest.resultType = .resultTypeCount

                let result = try context.execute(batchDeleteRequest) as? NSBatchDeleteResult
                let deletedCount = result?.result as? Int ?? 0

                if deletedCount > 0 {
                    let duration = CFAbsoluteTimeGetCurrent() - startTime
                    Log.info("Removed \(deletedCount) orphaned conversation participants in \(String(format: "%.3f", duration))s", category: .coreData)
                }
            } catch {
                Log.error("Failed to cleanup orphaned conversation participants", category: .coreData, error: error)
            }
        }
    }

    /// Removes orphaned MessageParticipant entries that reference non-existent messages.
    func removeOrphanedMessageParticipants(in context: NSManagedObjectContext) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        await context.perform {
            // Use batch delete for efficiency - find participants where message is nil
            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "MessageParticipant")
            fetchRequest.predicate = NSPredicate(format: "message == nil")
            fetchRequest.resultType = .managedObjectIDResultType

            do {
                guard let objectIDs = try context.fetch(fetchRequest) as? [NSManagedObjectID],
                      !objectIDs.isEmpty else {
                    return
                }

                let batchDeleteRequest = NSBatchDeleteRequest(objectIDs: objectIDs)
                batchDeleteRequest.resultType = .resultTypeCount

                let result = try context.execute(batchDeleteRequest) as? NSBatchDeleteResult
                let deletedCount = result?.result as? Int ?? 0

                if deletedCount > 0 {
                    let duration = CFAbsoluteTimeGetCurrent() - startTime
                    Log.info("Removed \(deletedCount) orphaned message participants in \(String(format: "%.3f", duration))s", category: .coreData)
                }
            } catch {
                Log.error("Failed to cleanup orphaned message participants", category: .coreData, error: error)
            }
        }
    }

    /// Removes orphaned Message entries that have no conversation.
    /// This can happen if a conversation is deleted but its messages weren't properly cascade-deleted.
    func removeOrphanedMessages(in context: NSManagedObjectContext) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        await context.perform {
            // Use batch delete for efficiency - find messages where conversation is nil
            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
            fetchRequest.predicate = NSPredicate(format: "conversation == nil")
            fetchRequest.resultType = .managedObjectIDResultType

            do {
                guard let objectIDs = try context.fetch(fetchRequest) as? [NSManagedObjectID],
                      !objectIDs.isEmpty else {
                    return
                }

                let batchDeleteRequest = NSBatchDeleteRequest(objectIDs: objectIDs)
                batchDeleteRequest.resultType = .resultTypeCount

                let result = try context.execute(batchDeleteRequest) as? NSBatchDeleteResult
                let deletedCount = result?.result as? Int ?? 0

                if deletedCount > 0 {
                    let duration = CFAbsoluteTimeGetCurrent() - startTime
                    Log.info("Removed \(deletedCount) orphaned messages in \(String(format: "%.3f", duration))s", category: .coreData)
                }
            } catch {
                Log.error("Failed to cleanup orphaned messages", category: .coreData, error: error)
            }
        }
    }

    /// Removes stale Label entities that have no associated messages.
    /// Excludes system labels (INBOX, SENT, etc.) that should always exist.
    func removeStaleLabels(in context: NSManagedObjectContext) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        // System labels that should never be removed
        let systemLabels = Set(["INBOX", "SENT", "TRASH", "DRAFT", "SPAM", "STARRED", "IMPORTANT", "UNREAD", "CATEGORY_PERSONAL", "CATEGORY_SOCIAL", "CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_FORUMS"])

        await context.perform {
            let request = Label.fetchRequest()
            request.fetchBatchSize = 50

            do {
                let labels = try context.fetch(request)
                var removedCount = 0

                for label in labels {
                    // Skip system labels
                    guard !systemLabels.contains(label.id) else { continue }

                    // Check if label has any messages
                    let messageCount = label.messages?.count ?? 0
                    if messageCount == 0 {
                        Log.debug("Removing stale label with no messages: \(label.name)", category: .coreData)
                        context.delete(label)
                        removedCount += 1
                    }
                }

                if removedCount > 0 {
                    try context.save()
                    let duration = CFAbsoluteTimeGetCurrent() - startTime
                    Log.info("Removed \(removedCount) stale labels in \(String(format: "%.3f", duration))s", category: .coreData)
                }
            } catch {
                Log.error("Failed to cleanup stale labels", category: .coreData, error: error)
            }
        }
    }

    /// Performs comprehensive orphaned data cleanup.
    /// Call this periodically (e.g., during incremental sync) to maintain database hygiene.
    func cleanupOrphanedData(in context: NSManagedObjectContext) async {
        Log.debug("Starting orphaned data cleanup", category: .coreData)
        let startTime = CFAbsoluteTimeGetCurrent()

        await removeOrphanedPendingActions(in: context)
        await removeOrphanedMessages(in: context)
        await removeOrphanedConversationParticipants(in: context)
        await removeOrphanedMessageParticipants(in: context)
        await removeStaleLabels(in: context)

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        Log.debug("Completed orphaned data cleanup in \(String(format: "%.3f", duration))s", category: .coreData)
    }
}

// MARK: - Duplicate Person Merge

extension DataCleanupService {

    /// Collapses `Person` rows that share a normalized email onto one survivor.
    ///
    /// `Person.email` has no uniqueness constraint, and the conversation
    /// creation serializer commits new conversation graphs in a dedicated
    /// context whose store fetch cannot see a Person still pending unsaved in
    /// the caller's batch — so any batch that opens a conversation for someone
    /// who already appeared in an earlier message inserts a second row for that
    /// address. Without this pass the rows are permanent, and `PersonFactory`'s
    /// fetchLimit-1 lookup picks between them arbitrarily, so the same address
    /// can resolve to a different display name or avatar from one fetch to the
    /// next.
    ///
    /// Both Person relationships cascade on delete, and a cascade that fired
    /// before its participations were moved would strand participant-less
    /// conversations — the exact failure the serializer's commit-the-whole-graph
    /// design exists to prevent. Core Data defers cascade propagation to
    /// `processPendingChanges`, so repointing after `delete(loser)` happens to
    /// work today; participations are moved first anyway, because anything that
    /// forces a pending-changes pass in between (a fetch, a relationship fault)
    /// would let the cascade win. That ordering is defensive, not covered by a
    /// discriminating test — swapping it leaves this suite green. Losers are
    /// deleted through the graph rather than by NSBatchDeleteRequest, which
    /// would cascade in the store behind the context's back.
    func mergeDuplicatePersons(in context: NSManagedObjectContext) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        await context.perform {
            let request = Person.fetchRequest()
            request.fetchBatchSize = 200

            let persons: [Person]
            do {
                persons = try context.fetch(request)
            } catch {
                Log.error("Failed to fetch persons for duplicate merge", category: .coreData, error: error)
                return
            }

            // Group on the normalized email. Rows written before PersonFactory
            // normalized its input may differ only by case, and a survivor left
            // un-normalized would stay invisible to the `email == %@` lookup
            // this pass exists to stabilize.
            var rowsByEmail: [String: [Person]] = [:]
            for person in persons {
                rowsByEmail[EmailNormalizer.normalize(person.email), default: []].append(person)
            }

            var mergedEmails: [String] = []
            var deletedObjectIDs: [NSManagedObjectID] = []

            for (email, rows) in rowsByEmail where rows.count > 1 {
                guard let survivor = Self.survivingPerson(among: rows, email: email) else { continue }
                if survivor.email != email {
                    survivor.email = email
                }

                for loser in rows where loser !== survivor {
                    Self.adoptMissingIdentityFields(from: loser, to: survivor, email: email)
                    Self.repointParticipations(from: loser, to: survivor)
                    deletedObjectIDs.append(loser.objectID)
                    context.delete(loser)
                }
                mergedEmails.append(email)
            }

            guard !deletedObjectIDs.isEmpty else { return }

            self.coreDataStack.saveIfNeeded(context: context)

            let changes = [NSDeletedObjectsKey: deletedObjectIDs]
            NSManagedObjectContext.mergeChanges(
                fromRemoteContextSave: changes,
                into: [self.coreDataStack.viewContext]
            )

            // Cached [email: Person] entries can still point at a deleted loser;
            // drop them so the next findOrCreate re-fetches the survivor.
            PersonFactory.resetCache(in: context)
            PersonDisplayInfoChangeNotification.invalidatePersonCacheAndPostLater(emails: mergedEmails)

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            Log.info(
                "Merged \(deletedObjectIDs.count) duplicate person rows across \(mergedEmails.count) emails in \(String(format: "%.3f", duration))s",
                category: .coreData
            )
        }
    }

    /// Picks the row that keeps the richest identity. The objectID tiebreak
    /// keeps the choice deterministic, so a rerun converges instead of
    /// ping-ponging the surviving row.
    private static func survivingPerson(among rows: [Person], email: String) -> Person? {
        rows.reduce(nil) { best, candidate in
            guard let best else { return candidate }
            if EmailNormalizer.isBetterDisplayName(candidate.displayName, than: best.displayName, forEmail: email) {
                return candidate
            }
            if EmailNormalizer.isBetterDisplayName(best.displayName, than: candidate.displayName, forEmail: email) {
                return best
            }
            if (candidate.avatarURL != nil) != (best.avatarURL != nil) {
                return candidate.avatarURL != nil ? candidate : best
            }
            let candidateKey = candidate.objectID.uriRepresentation().absoluteString
            let bestKey = best.objectID.uriRepresentation().absoluteString
            return candidateKey < bestKey ? candidate : best
        }
    }

    /// Carries across identity fields the survivor lacks, before the loser goes.
    private static func adoptMissingIdentityFields(from loser: Person, to survivor: Person, email: String) {
        if EmailNormalizer.isBetterDisplayName(loser.displayName, than: survivor.displayName, forEmail: email) {
            survivor.displayName = loser.displayName
        }
        if survivor.avatarURL == nil, let avatarURL = loser.avatarURL {
            survivor.avatarURL = avatarURL
        }
    }

    /// Moves the loser's participations onto the survivor. A participation the
    /// survivor already holds for the same conversation (or the same message in
    /// the same role) is deleted instead of moved: repointing it would list the
    /// person twice in one conversation.
    private static func repointParticipations(from loser: Person, to survivor: Person) {
        let survivorConversations = Set(
            (survivor.conversationParticipations ?? []).compactMap { $0.conversation?.objectID }
        )
        for participation in loser.conversationParticipations ?? [] {
            if let conversationID = participation.conversation?.objectID,
               survivorConversations.contains(conversationID) {
                participation.managedObjectContext?.delete(participation)
            } else {
                participation.person = survivor
            }
        }

        let survivorMessages = Set(
            (survivor.messageParticipations ?? []).compactMap { participation -> String? in
                guard let message = participation.message else { return nil }
                return Self.messageParticipationKey(message: message, kind: participation.kind)
            }
        )
        for participation in loser.messageParticipations ?? [] {
            let key = participation.message.map {
                Self.messageParticipationKey(message: $0, kind: participation.kind)
            }
            if let key, survivorMessages.contains(key) {
                participation.managedObjectContext?.delete(participation)
            } else {
                participation.person = survivor
            }
        }
    }

    private static func messageParticipationKey(message: Message, kind: String) -> String {
        "\(message.objectID.uriRepresentation().absoluteString)|\(kind)"
    }
}

// MARK: - Duplicate Label Merge

extension DataCleanupService {

    /// Collapses `Label` rows that share a Gmail label id onto one survivor.
    ///
    /// `Label.id` has no uniqueness constraint (pre-v3 entities don't gain
    /// constraints until v4, after repairs soak), and duplicate rows are worse
    /// than cosmetic: `LabelPersister` builds id-keyed dictionaries from
    /// fetched labels, which trapped on duplicates until it switched to
    /// first-wins collapsing. This pass repairs the store so that collapse is
    /// a transient shield, not the permanent state.
    ///
    /// Unlike Person, `Label.messages` is Nullify — no cascade risk — but the
    /// message repointing must still precede the delete so no message loses a
    /// label association mid-merge.
    func mergeDuplicateLabels(in context: NSManagedObjectContext) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        await context.perform {
            let request = Label.fetchRequest()
            request.fetchBatchSize = 100

            let labels: [Label]
            do {
                labels = try context.fetch(request)
            } catch {
                Log.error("Failed to fetch labels for duplicate merge", category: .coreData, error: error)
                return
            }

            var rowsById: [String: [Label]] = [:]
            for label in labels {
                rowsById[label.id, default: []].append(label)
            }

            var deletedObjectIDs: [NSManagedObjectID] = []

            for (_, rows) in rowsById where rows.count > 1 {
                // Deterministic survivor so reruns converge; Gmail's canonical
                // name arrives via saveLabels upserts either way.
                guard let survivor = rows.min(by: {
                    $0.objectID.uriRepresentation().absoluteString
                        < $1.objectID.uriRepresentation().absoluteString
                }) else { continue }

                for loser in rows where loser !== survivor {
                    for message in loser.messages ?? [] {
                        message.removeFromLabels(loser)
                        message.addToLabels(survivor)
                    }
                    deletedObjectIDs.append(loser.objectID)
                    context.delete(loser)
                }
            }

            guard !deletedObjectIDs.isEmpty else { return }

            self.coreDataStack.saveIfNeeded(context: context)

            let changes = [NSDeletedObjectsKey: deletedObjectIDs]
            NSManagedObjectContext.mergeChanges(
                fromRemoteContextSave: changes,
                into: [self.coreDataStack.viewContext]
            )

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            Log.info(
                "Merged \(deletedObjectIDs.count) duplicate label rows in \(String(format: "%.3f", duration))s",
                category: .coreData
            )
        }
    }
}
