import Foundation
import CoreData

// MARK: - Archive Model Migration

extension DataCleanupService {

    /// Migrates existing conversations to the new archive model
    /// - Sets archivedAt for conversations that are hidden or have no inbox messages
    /// - Sets participantHash for conversations that don't have one
    func migrateConversationsToArchiveModel(in context: NSManagedObjectContext) async {
        let hasDoneMigration = migrationFlags.bool(forKey: "hasDoneArchiveModelMigrationV1")
        guard !hasDoneMigration else { return }

        Log.info("Starting archive model migration...", category: .coreData)
        let startTime = CFAbsoluteTimeGetCurrent()

        await context.perform {
            let request = Conversation.fetchRequest()
            request.fetchBatchSize = 50
            request.relationshipKeyPathsForPrefetching = ["participants", "participants.person"]

            guard let conversations = try? context.fetch(request) else {
                Log.warning("Failed to fetch conversations for migration", category: .coreData)
                return
            }

            var archivedCount = 0
            var participantHashCount = 0

            for conversation in conversations {
                // Set archivedAt for archived conversations
                if conversation.archivedAt == nil && (conversation.hidden || !conversation.hasInbox) {
                    conversation.archivedAt = conversation.lastMessageDate ?? Date()
                    archivedCount += 1
                }

                // Set participantHash if missing
                if conversation.participantHash == nil {
                    // Build participant hash from participants
                    let emails = conversation.participantsArray.map { normalizedEmail($0) }
                    if !emails.isEmpty {
                        conversation.participantHash = calculateParticipantHash(from: emails)
                        participantHashCount += 1
                    }
                }
            }

            self.coreDataStack.saveIfNeeded(context: context)

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            Log.info("Archive model migration complete in \(String(format: "%.2f", duration))s - archivedAt: \(archivedCount), participantHash: \(participantHashCount)", category: .coreData)
        }

        migrationFlags.set(true, forKey: "hasDoneArchiveModelMigrationV1")
    }

    /// Fixes conversations with incorrect participantHashes (e.g., ones that include the user's email)
    /// and merges them with the correct conversation.
    func fixAndMergeIncorrectParticipantHashes(in context: NSManagedObjectContext) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Use the same alias source as sync-side identity (AliasManager, which
        // includes send-as and self-contact aliases). Recomputing hashes with a
        // narrower alias set than the router uses would make this pass and the
        // router disagree and flip-flop conversations between hashes.
        let myAliases = await identityAliasProvider(context)
        guard !myAliases.isEmpty else { return }

        await context.perform { [self] in
            // Fetch all active conversations
            let request = Conversation.fetchRequest()
            request.predicate = ConversationPredicates.active
            request.returnsObjectsAsFaults = false
            request.relationshipKeyPathsForPrefetching = ["participants", "participants.person"]

            guard let conversations = try? context.fetch(request) else { return }

            var mergedCount = 0
            var deletedObjectIDs = [NSManagedObjectID]()

            // Group conversations by their CORRECT participantHash (excluding user's email)
            var byCorrectHash: [String: [Conversation]] = [:]

            for conv in conversations {
                // Calculate the correct participantHash by excluding user's aliases
                let currentParticipants = conv.participantsArray
                let correctParticipants = currentParticipants
                    .map { normalizedEmail($0) }
                    .filter { !myAliases.contains($0) }

                if correctParticipants.isEmpty { continue }

                let correctHash = calculateParticipantHash(from: correctParticipants)

                byCorrectHash[correctHash, default: []].append(conv)

                // Update the participantHash if it was wrong
                if conv.participantHash != correctHash {
                    Log.debug("Fixing participantHash for conversation: \(conv.displayName ?? "unknown")", category: .coreData)
                    conv.participantHash = correctHash
                }
            }

            // Merge groups with multiple conversations
            for (hash, group) in byCorrectHash where group.count > 1 {
                Log.debug("Merging \(group.count) conversations with corrected participantHash: \(hash.prefix(16))...", category: .coreData)

                guard let winner = conversationManager.selectWinnerConversation(from: group) else {
                    continue
                }
                let losers = group.filter { $0 != winner }

                for loser in losers {
                    conversationManager.mergeConversation(from: loser, into: winner)
                    deletedObjectIDs.append(loser.objectID)
                    context.delete(loser)
                    mergedCount += 1
                }
            }

            if mergedCount > 0 || context.hasChanges {
                coreDataStack.saveIfNeeded(context: context)

                if !deletedObjectIDs.isEmpty {
                    let changes = [NSDeletedObjectsKey: deletedObjectIDs]
                    NSManagedObjectContext.mergeChanges(
                        fromRemoteContextSave: changes,
                        into: [coreDataStack.viewContext]
                    )
                }

                let duration = CFAbsoluteTimeGetCurrent() - startTime
                Log.info("Fixed and merged \(mergedCount) conversations with incorrect participantHashes in \(String(format: "%.3f", duration))s", category: .coreData)
            }
        }
    }

}

// MARK: - Participant-Set Split Migration

extension DataCleanupService {

    static let participantSetSplitMigrationKey = "hasDoneParticipantSetSplitV1"

    /// One-time migration: re-buckets every message into the conversation matching
    /// its strict participant set (From+To+Cc minus the user's aliases). Splits
    /// Gmail threads whose recipients changed mid-thread and folds mis-homed
    /// messages into the existing conversation for their set — the inverse of the
    /// retired gmThreadId merge, matching the strict participant-keyed router.
    ///
    /// Idempotent: interim saves are safe because a re-run skips every message
    /// whose conversation already carries its strict hash. The flag is written
    /// only after the final phase saves successfully.
    func splitConversationsByParticipantSetIfNeeded(in context: NSManagedObjectContext) async {
        guard !migrationFlags.bool(forKey: Self.participantSetSplitMigrationKey) else { return }

        // Aliases are load-bearing for identity hashes: they must match what the
        // router excludes. Without an Account (pre-auth) we cannot compute strict
        // identities — return WITHOUT burning the flag so the next cleanup retries.
        let myAliases = await identityAliasProvider(context)
        guard !myAliases.isEmpty else { return }

        Log.info("Starting participant-set conversation split migration...", category: .coreData)
        let startTime = CFAbsoluteTimeGetCurrent()

        // Interim rollups run on the background context queue, where the
        // @MainActor AuthSession-backed email source is unavailable — derive
        // the rollup email from the Account row instead.
        let myEmail: String = await context.perform {
            (try? context.fetch(Account.fetchRequest()).first)?.email ?? ""
        }

        // Phase 1: re-home each message whose strict hash differs from its conversation's.
        guard let rehome = await rehomeMessagesByParticipantSet(
            myAliases: myAliases,
            myEmail: myEmail,
            in: context
        ) else {
            Log.warning("Participant-set split migration aborted; will retry next cleanup", category: .coreData)
            return
        }
        let touchedIDs = rehome.touchedConversationIDs

        // Phase 2: sweep emptied shells, collapse duplicate actives, repair stale
        // participant rows, then recompute rollups for everything the re-home touched.
        await deleteEmptiedConversations(
            lastDestinationBySource: rehome.lastDestinationBySource,
            in: context
        )
        await mergeActiveConversationDuplicates(in: context)
        await rebuildParticipantRowsForRehomedConversations(
            touchedIDs: touchedIDs,
            myAliases: myAliases,
            in: context
        )
        await conversationManager.updateRollupsForModifiedConversations(
            conversationIDs: touchedIDs,
            in: context
        )

        guard await context.performSaveIfNeeded(caller: "DataCleanupService.splitConversationsByParticipantSet") else {
            Log.warning("Participant-set split migration final save failed; will retry next cleanup", category: .coreData)
            return
        }

        migrationFlags.set(true, forKey: Self.participantSetSplitMigrationKey)

        // Re-homed message lists must not be served from stale caches.
        await ConversationCache.shared.clearAllCaches()

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        Log.info("Participant-set conversation split migration complete in \(String(format: "%.2f", duration))s (touched \(touchedIDs.count) conversation(s))", category: .coreData)
    }

    struct RehomeResult {
        let touchedConversationIDs: Set<NSManagedObjectID>
        /// Where each source conversation's messages last went, so user state
        /// (pinned/muted) can follow a fully-drained shell to its destination.
        let lastDestinationBySource: [NSManagedObjectID: NSManagedObjectID]
    }

    /// Phase 1: walks all messages in deterministic order and reassigns any whose
    /// strict participant hash differs from its conversation's stored hash.
    /// Returns the objectIDs of every conversation that gained or lost a message,
    /// or nil when the initial fetch fails (caller retries next cleanup).
    private func rehomeMessagesByParticipantSet(
        myAliases: Set<String>,
        myEmail: String,
        in context: NSManagedObjectContext
    ) async -> RehomeResult? {
        await context.perform { [self] in
            let request = Message.fetchRequest()
            request.sortDescriptors = [
                NSSortDescriptor(key: "internalDate", ascending: true),
                NSSortDescriptor(key: "id", ascending: true)
            ]
            request.fetchBatchSize = 500
            request.relationshipKeyPathsForPrefetching = [
                "participants", "participants.person", "conversation", "labels"
            ]

            let messages: [Message]
            do {
                messages = try context.fetch(request)
            } catch {
                Log.error("Failed to fetch messages for participant-set split migration", category: .coreData, error: error)
                return nil
            }

            var destinationByHash: [String: Conversation] = [:]
            var touchedConversationIDs: Set<NSManagedObjectID> = []
            var lastDestinationBySource: [NSManagedObjectID: NSManagedObjectID] = [:]
            var touchedThisBatch: Set<Conversation> = []
            var movedCount = 0
            var processed = 0

            for message in messages {
                autoreleasepool {
                    // Messages without derivable identity (optimistic in-flight
                    // sends have no participant rows and no senderEmail) stay put,
                    // keeping their conversations alive for send reconciliation.
                    guard let identity = message.strictParticipantSetIdentity(myAliases: myAliases) else { return }

                    let currentHash = message.conversation?.participantHash?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    // Epoch preservation: any conversation (active or archived)
                    // already carrying this message's strict hash keeps it.
                    guard currentHash != identity.participantHash else { return }

                    let destination: Conversation
                    if let memo = destinationByHash[identity.participantHash] {
                        destination = memo
                    } else if let existing = fetchConversationForRehome(
                        participantHash: identity.participantHash,
                        in: context
                    ) {
                        destination = existing
                        destinationByHash[identity.participantHash] = existing
                    } else {
                        guard let created = try? ConversationFactory.create(
                            for: makeConversationIdentity(from: identity),
                            initialLastMessageDate: message.internalDate,
                            initialSnippet: message.conversationPreviewText,
                            initialInboxSeed: ConversationInboxSeed(
                                isInboxArrival: (message.labels ?? []).contains { $0.id == "INBOX" },
                                isUnread: message.isUnread,
                                messageDate: message.internalDate
                            ),
                            in: context
                        ) else { return }
                        // Permanent ID now: temporary IDs recorded in touched sets
                        // would go stale at the first interim save.
                        try? context.obtainPermanentIDs(for: [created])
                        destination = created
                        destinationByHash[identity.participantHash] = created
                    }

                    if let previous = message.conversation {
                        touchedConversationIDs.insert(previous.objectID)
                        touchedThisBatch.insert(previous)
                        lastDestinationBySource[previous.objectID] = destination.objectID
                    }
                    message.conversation = destination
                    touchedConversationIDs.insert(destination.objectID)
                    touchedThisBatch.insert(destination)
                    movedCount += 1
                }

                processed += 1
                if processed % 500 == 0 {
                    if !touchedThisBatch.isEmpty {
                        // Roll up before each interim save so no published row carries
                        // stale unread counts; the final pass recomputes everything.
                        for conversation in touchedThisBatch where !conversation.isDeleted {
                            conversationManager.updateConversationRollups(for: conversation, myEmail: myEmail)
                        }
                        coreDataStack.saveIfNeeded(context: context)
                        touchedThisBatch.removeAll()
                    }
                    // Release faulted rows unconditionally: memory grows with
                    // messages READ, not messages moved, so a mostly-correct
                    // store still needs periodic re-faulting.
                    context.refreshAllObjects()
                }
            }

            for conversation in touchedThisBatch where !conversation.isDeleted {
                conversationManager.updateConversationRollups(for: conversation, myEmail: myEmail)
            }
            coreDataStack.saveIfNeeded(context: context)

            if movedCount > 0 {
                Log.info("Participant-set split re-homed \(movedCount) message(s) across \(touchedConversationIDs.count) conversation(s)", category: .coreData)
            }
            return RehomeResult(
                touchedConversationIDs: touchedConversationIDs,
                lastDestinationBySource: lastDestinationBySource
            )
        }
    }

    /// Selection-only destination lookup: folds re-homed historical messages into
    /// the most recent epoch for their set (active preferred, else newest
    /// archived). `reactivateArchivedIfNeeded: true` here only widens SELECTION
    /// to archived candidates; nothing un-archives them in this pass — the final
    /// rollup's `applyArchiveState` reactivates only if the folded messages
    /// carry INBOX.
    private func fetchConversationForRehome(
        participantHash: String,
        in context: NSManagedObjectContext
    ) -> Conversation? {
        let request = Conversation.fetchRequest()
        request.predicate = NSPredicate(format: "participantHash == %@", participantHash)
        request.includesPendingChanges = true

        guard let candidates = try? context.fetch(request), !candidates.isEmpty else { return nil }
        return ConversationRoutingPolicy().selectParticipantHashConversation(
            from: candidates,
            reactivateArchivedIfNeeded: true
        )
    }

    /// Phase 2a: deletes conversations the re-home emptied. Deferred to the end of
    /// the pass because a source emptied early can become a destination later.
    ///
    /// Sweeps store-wide rather than only this run's touched set: a crash between
    /// an interim save and this phase leaves fully-drained shells that a re-run
    /// never touches again (no movers remain), and the generic
    /// `removeEmptyConversations` pass cannot catch them because its predicate
    /// requires zero participant rows. A creation-time grace period protects
    /// freshly created compose shells alongside the pending-send guard.
    private func deleteEmptiedConversations(
        lastDestinationBySource: [NSManagedObjectID: NSManagedObjectID],
        in context: NSManagedObjectContext
    ) async {
        let deletedObjectIDs: [NSManagedObjectID] = await context.perform { [self] in
            // Conversations referenced by in-flight optimistic sends must survive
            // even when they look empty here: their optimistic message may be
            // unsaved on the view context and invisible to this background context.
            let recordRequest = OutboundSendMutationRecord.fetchRequest()
            let pendingSendConversationIds = Set(
                ((try? context.fetch(recordRequest)) ?? []).compactMap(\.conversationId)
            )

            let request = Conversation.fetchRequest()
            request.predicate = NSPredicate(format: "messages.@count == 0")
            let emptyConversations = (try? context.fetch(request)) ?? []
            let creationGrace: TimeInterval = 60 * 60

            var deleted: [NSManagedObjectID] = []
            for conversation in emptyConversations {
                guard !pendingSendConversationIds.contains(conversation.id) else { continue }
                if let createdAt = conversation.createdAt,
                   Date().timeIntervalSince(createdAt) < creationGrace {
                    continue
                }

                // A fully-drained shell's identity effectively moved; carry the
                // user's pinned/muted state to where its messages went.
                if conversation.pinned || conversation.muted,
                   let destinationID = lastDestinationBySource[conversation.objectID],
                   let destination = try? context.existingObject(with: destinationID) as? Conversation,
                   !destination.isDeleted {
                    destination.pinned = destination.pinned || conversation.pinned
                    destination.muted = destination.muted || conversation.muted
                }

                deleted.append(conversation.objectID)
                context.delete(conversation)
            }

            if !deleted.isEmpty || context.hasChanges {
                coreDataStack.saveIfNeeded(context: context)
            }
            return deleted
        }

        if !deletedObjectIDs.isEmpty {
            NSManagedObjectContext.mergeChanges(
                fromRemoteContextSave: [NSDeletedObjectsKey: deletedObjectIDs],
                into: [coreDataStack.viewContext]
            )
            Log.info("Participant-set split removed \(deletedObjectIDs.count) emptied conversation shell(s)", category: .coreData)
        }
    }

    /// Phase 2c: conversations that kept their hash through the re-home can still
    /// carry participant rows from their thread-merged past. Replies address the
    /// conversation's participant rows, and the maintenance hash-fix pass
    /// recomputes hashes FROM those rows, so stale rows would send replies to the
    /// wrong people and fight the router. Rebuild rows from message-derived
    /// identity wherever they diverge.
    private func rebuildParticipantRowsForRehomedConversations(
        touchedIDs: Set<NSManagedObjectID>,
        myAliases: Set<String>,
        in context: NSManagedObjectContext
    ) async {
        await context.perform {
            var rebuiltCount = 0

            for objectID in touchedIDs {
                guard let conversation = try? context.existingObject(with: objectID) as? Conversation,
                      !conversation.isDeleted,
                      let conversationHash = conversation.participantHash else { continue }

                // Post re-home, every message with derivable identity in this
                // conversation shares its hash; any of them defines the expected
                // rows (lazy: one identity computation, not one per message).
                guard let identity = (conversation.messages ?? []).lazy
                    .compactMap({ $0.strictParticipantSetIdentity(myAliases: myAliases) })
                    .first(where: { $0.participantHash == conversationHash }) else { continue }

                let expected = Set(identity.participants)
                let current = Set(
                    (conversation.participants ?? []).compactMap { $0.person }.map { normalizedEmail($0.email) }
                )
                guard expected != current else { continue }

                for row in conversation.participants ?? [] {
                    context.delete(row)
                }
                for email in identity.participants {
                    guard let person = try? PersonFactory.findOrCreate(email: email, displayName: nil, in: context) else { continue }
                    try? ConversationFactory.createParticipant(
                        person: person,
                        conversation: conversation,
                        role: .normal,
                        in: context
                    )
                }
                conversation.conversationType = identity.type
                rebuiltCount += 1
            }

            if rebuiltCount > 0 {
                self.coreDataStack.saveIfNeeded(context: context)
                Log.info("Rebuilt participant rows for \(rebuiltCount) conversation(s) after participant-set split", category: .coreData)
            }
        }
    }
}
