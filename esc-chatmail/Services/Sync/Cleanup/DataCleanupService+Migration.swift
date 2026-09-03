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
            let pendingSendConversationIds: Set<UUID>
            let pendingActionsByConversationID: [UUID: [PendingAction]]
            do {
                pendingSendConversationIds = try pendingSendConversationIDs(in: context)
                pendingActionsByConversationID = try PendingAction.referencesByConversationID(
                    in: context
                )
            } catch {
                Log.error(
                    "Failed to fetch protected references before participant hash repair",
                    category: .coreData,
                    error: error
                )
                return
            }

            // Group conversations by their CORRECT participantHash (excluding user's email)
            var byCorrectHash: [String: [Conversation]] = [:]

            for conv in conversations {
                // List conversations are keyed by their "l|" List-Id hash, not
                // by their participant rows. Recomputing a "p|" hash here would
                // clobber the list key AND merge the list chat into any
                // participant chat sharing the same row set.
                if conv.conversationType == .list { continue }

                // An in-flight optimistic send can reference this conversation
                // while its message exists only in the view context. Leave the
                // shell completely untouched until reconciliation finishes;
                // deleting its final excluded participant here would make the
                // following empty-conversation sweep delete the send's anchor.
                if pendingSendConversationIds.contains(conv.id) { continue }

                // Match routing identity by excluding both the user's aliases
                // and Hide-My-Email placeholder participants.
                var hasIdentityRow = false
                let correctParticipants = Array(conv.participants ?? [])
                    .compactMap { participant -> String? in
                        guard let person = participant.person else {
                            return nil
                        }
                        hasIdentityRow = true
                        if EmailNormalizer.isHideMyEmailDisplayName(person.displayName) {
                            // Hash parity is not enough: replies read these rows
                            // directly, so retain no excluded relay recipient.
                            context.delete(participant)
                            return nil
                        }
                        return normalizedEmail(person.email)
                    }
                    .filter { !$0.isEmpty }
                guard hasIdentityRow else { continue }

                let correctIdentity = makeParticipantSetIdentity(
                    normalizedEmails: Set(correctParticipants),
                    myAliases: myAliases
                )
                let correctHash = correctIdentity.participantHash

                byCorrectHash[correctHash, default: []].append(conv)
                conv.conversationType = correctIdentity.type

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
                    for action in pendingActionsByConversationID[loser.id] ?? [] {
                        action.conversationId = winner.id
                    }
                    conversationManager.mergeConversation(from: loser, into: winner)
                    deletedObjectIDs.append(loser.objectID)
                    context.delete(loser)
                    mergedCount += 1
                }
            }

            if mergedCount > 0 || context.hasChanges {
                guard coreDataStack.saveIfNeeded(
                    context: context,
                    caller: "DataCleanupService.fixAndMergeIncorrectParticipantHashes"
                ) else {
                    context.rollback()
                    Log.warning(
                        "Participant hash repair save failed; skipping deletion merge",
                        category: .coreData
                    )
                    return
                }

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

// MARK: - RFC 2047 Header Text Repair

extension DataCleanupService {

    static let rfc2047HeaderTextRepairKey = "hasDecodedRFC2047HeaderTextV1"

    /// One-time repair: earlier builds persisted raw RFC 2047 encoded-words
    /// ("=?utf-8?B?...?=") straight from From/Subject headers into display
    /// fields, which rendered as garbage sender names. Ingestion now decodes
    /// at parse time (EmailNormalizer / MessageProcessor); this pass decodes
    /// what already landed in the store.
    ///
    /// Idempotent: decoding an already-decoded value is a no-op, so interim
    /// saves are safe and the flag is only written after a successful save.
    func decodeRFC2047HeaderTextIfNeeded(in context: NSManagedObjectContext) async {
        guard !migrationFlags.bool(forKey: Self.rfc2047HeaderTextRepairKey) else { return }

        let startTime = CFAbsoluteTimeGetCurrent()
        // "=?" appears in every encoded word; CONTAINS narrows the scan to
        // candidate rows and the decoder verifies the full "=?...?=" shape.
        let encodedWordMarker = "=?"

        let result: (changedPersonEmails: Set<String>, personCount: Int, messageCount: Int, conversationCount: Int) = await context.perform {
            var changedPersonEmails: Set<String> = []
            var personCount = 0
            var messageCount = 0
            var conversationCount = 0

            let personRequest = Person.fetchRequest()
            personRequest.predicate = NSPredicate(format: "displayName CONTAINS %@", encodedWordMarker)
            personRequest.fetchBatchSize = 100
            for person in (try? context.fetch(personRequest)) ?? [] {
                guard let garbled = person.displayName else { continue }
                let decoded = EmailNormalizer.sanitizeDisplayName(garbled)
                guard decoded != garbled else { continue }
                person.displayName = decoded.isEmpty ? nil : decoded
                changedPersonEmails.insert(person.email)
                personCount += 1
            }

            let messageRequest = Message.fetchRequest()
            messageRequest.predicate = NSPredicate(
                format: "senderName CONTAINS %@ OR subject CONTAINS %@",
                encodedWordMarker, encodedWordMarker
            )
            messageRequest.fetchBatchSize = 200
            for message in (try? context.fetch(messageRequest)) ?? [] {
                var changed = false
                if let garbled = message.senderName {
                    let decoded = EmailNormalizer.sanitizeDisplayName(garbled)
                    if decoded != garbled {
                        message.senderName = decoded.isEmpty ? nil : decoded
                        changed = true
                    }
                }
                if let garbled = message.subject {
                    let decoded = RFC2047Decoder.decode(garbled)
                    if decoded != garbled {
                        message.subject = decoded
                        changed = true
                    }
                }
                if changed { messageCount += 1 }
            }

            let conversationRequest = Conversation.fetchRequest()
            conversationRequest.predicate = NSPredicate(
                format: "displayName CONTAINS %@ OR snippet CONTAINS %@",
                encodedWordMarker, encodedWordMarker
            )
            conversationRequest.fetchBatchSize = 100
            for conversation in (try? context.fetch(conversationRequest)) ?? [] {
                var changed = false
                if let garbled = conversation.displayName {
                    let decoded = RFC2047Decoder.decode(garbled)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if decoded != garbled, !decoded.isEmpty {
                        conversation.displayName = decoded
                        changed = true
                    }
                }
                if let garbled = conversation.snippet {
                    let decoded = RFC2047Decoder.decode(garbled)
                    if decoded != garbled {
                        conversation.snippet = decoded
                        changed = true
                    }
                }
                if changed { conversationCount += 1 }
            }

            return (changedPersonEmails, personCount, messageCount, conversationCount)
        }

        guard await context.performSaveIfNeeded(caller: "DataCleanupService.decodeRFC2047HeaderText") else {
            Log.warning("RFC 2047 header text repair save failed; will retry next cleanup", category: .coreData)
            return
        }

        migrationFlags.set(true, forKey: Self.rfc2047HeaderTextRepairKey)

        let totalChanged = result.personCount + result.messageCount + result.conversationCount
        if totalChanged > 0 {
            // Cached person rows may still carry garbled names; invalidate
            // them and notify readers so the decoded values publish.
            PersonDisplayInfoChangeNotification.invalidatePersonCacheAndPostLater(
                emails: result.changedPersonEmails
            )

            let duration = CFAbsoluteTimeGetCurrent() - startTime
            Log.info(
                "RFC 2047 header text repair decoded \(result.personCount) person(s), \(result.messageCount) message(s), \(result.conversationCount) conversation(s) in \(String(format: "%.2f", duration))s",
                category: .coreData
            )
        }
    }
}

// MARK: - Participant-Set Split Migration

extension DataCleanupService {

    // Bump whenever strict participant extraction changes so stores that already
    // completed an older pass are re-evaluated with the corrected identity rule.
    static let participantSetSplitMigrationKey = "hasDoneParticipantSetSplitV2"

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
        let rowRepairCandidateIDs = rehome.participantRowRepairCandidateIDs

        // Phase 2: sweep emptied shells, collapse duplicate actives, repair stale
        // participant rows, then recompute rollups for everything the re-home touched.
        guard await deleteEmptiedConversations(
            lastDestinationBySource: rehome.lastDestinationBySource,
            in: context
        ) else {
            Log.warning("Participant-set split migration sweep failed; will retry next cleanup", category: .coreData)
            return
        }
        guard await mergeActiveConversationDuplicates(in: context) else {
            await context.perform { context.rollback() }
            Log.warning("Participant-set duplicate merge failed; will retry next cleanup", category: .coreData)
            return
        }
        guard await rebuildParticipantRowsForRehomedConversations(
            candidateIDs: rowRepairCandidateIDs,
            myAliases: myAliases,
            in: context
        ) else {
            Log.warning("Participant-set row rebuild failed; will retry next cleanup", category: .coreData)
            return
        }
        guard await conversationManager.updateRollupsForModifiedConversations(
            conversationIDs: touchedIDs,
            in: context
        ) else {
            await context.perform { context.rollback() }
            Log.warning("Participant-set rollup refresh failed; will retry next cleanup", category: .coreData)
            return
        }

        guard await context.performSaveIfNeeded(caller: "DataCleanupService.splitConversationsByParticipantSet") else {
            Log.warning("Participant-set split migration final save failed; will retry next cleanup", category: .coreData)
            return
        }

        guard !rehome.blockedByProtectedConversation else {
            Log.debug(
                "Participant-set split repaired available conversations but left its flag clear for a protected send anchor",
                category: .coreData
            )
            return
        }

        migrationFlags.set(true, forKey: Self.participantSetSplitMigrationKey)

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        Log.info("Participant-set conversation split migration complete in \(String(format: "%.2f", duration))s (touched \(touchedIDs.count) conversation(s))", category: .coreData)
    }

    struct RehomeResult {
        let touchedConversationIDs: Set<NSManagedObjectID>
        /// Every non-protected conversation with a resident, derivable strict
        /// identity. Unlike `touchedConversationIDs`, this is repopulated on a
        /// retry after Phase 1 already saved its moves, so a failed Phase 2c
        /// save cannot permanently skip participant-row repair.
        let participantRowRepairCandidateIDs: Set<NSManagedObjectID>
        /// Where each source conversation's messages last went, so user state
        /// (pinned/muted) can follow a fully-drained shell to its destination.
        let lastDestinationBySource: [NSManagedObjectID: NSManagedObjectID]
        /// A retained send anchor still needs re-homing after its record clears.
        let blockedByProtectedConversation: Bool
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
            var participantRowRepairCandidateIDs: Set<NSManagedObjectID> = []
            var lastDestinationBySource: [NSManagedObjectID: NSManagedObjectID] = [:]
            var drainedSourceIDs: Set<NSManagedObjectID> = []
            var createdDestinationIDs: Set<NSManagedObjectID> = []
            var touchedThisBatch: Set<Conversation> = []
            var movedCount = 0
            var processed = 0
            var blockedByProtectedConversation = false

            let outboundSendRecords: [OutboundSendMutationRecord]
            let pendingSendConversationIds: Set<UUID>
            do {
                outboundSendRecords = try context.fetch(OutboundSendMutationRecord.fetchRequest())
                pendingSendConversationIds = Set(outboundSendRecords.compactMap(\.conversationId))
            } catch {
                Log.error(
                    "Failed to fetch pending sends before participant-set re-home",
                    category: .coreData,
                    error: error
                )
                return nil
            }
            let hasRollbackCapableSend = outboundSendRecords.contains { record in
                record.remoteCommittedThreadId == nil &&
                    (record.remoteCommittedMessageId == nil ||
                        record.remoteCommittedMessageId == OutboundSendRemoteState.inFlightMessageID)
            }
            guard !hasRollbackCapableSend else {
                // A send rollback owns the pending conversation's membership and
                // rollup snapshot while the network request is in flight. This
                // state is brief; retained failed/ambiguous records are instead
                // skipped per-anchor below so they cannot starve mailbox repair.
                Log.debug(
                    "Deferring participant-set split while a rollback-capable send is pending",
                    category: .coreData
                )
                return nil
            }

            for message in messages {
                var processingError: Error?
                autoreleasepool {
                    // Messages without derivable identity (optimistic in-flight
                    // sends have no participant rows and no senderEmail) stay put,
                    // keeping their conversations alive for send reconciliation.
                    guard let identity = message.strictParticipantSetIdentity(myAliases: myAliases) else {
                        return
                    }
                    let source = message.conversation
                    let currentHash = source?.participantHash?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if currentHash == identity.participantHash {
                        if let source {
                            if pendingSendConversationIds.contains(source.id) {
                                if conversationNeedsParticipantRowRepair(
                                    source,
                                    identity: identity
                                ) {
                                    blockedByProtectedConversation = true
                                }
                            } else {
                                participantRowRepairCandidateIDs.insert(source.objectID)
                            }
                        }
                        return
                    }
                    // List-Id is persisted on the message and remains an
                    // independently authoritative destination key.
                    if let source, identity.type != .list {
                        // Older persistence retained only the first mailbox
                        // from a multi-address From header. Without the raw
                        // header, a missing normal sender is indistinguishable
                        // from a thread-merged row. Move only when the source's
                        // validated rows reduce to the same strict identity.
                        guard let repairedSourceIdentity = validatedConversationIdentity(
                            source,
                            myAliases: myAliases
                        ), repairedSourceIdentity.participantHash == identity.participantHash else {
                            return
                        }
                    }
                    if let source,
                       pendingSendConversationIds.contains(source.id) {
                        blockedByProtectedConversation = true
                        return
                    }

                    do {
                        let destination: Conversation
                        if let cached = destinationByHash[identity.participantHash],
                           !drainedSourceIDs.contains(cached.objectID),
                           !pendingSendConversationIds.contains(cached.id) {
                            destination = cached
                        } else {
                            let lookup = try fetchConversationForRehome(
                                participantHash: identity.participantHash,
                                excluding: drainedSourceIDs,
                                excludingConversationIDs: pendingSendConversationIds,
                                in: context
                            )
                            if let existing = lookup.conversation {
                                destinationByHash[identity.participantHash] = existing
                                destination = existing
                            } else {
                                guard !lookup.hasProtectedCandidate else {
                                    // Creating a parallel same-hash shell would
                                    // permanently split this chat because the
                                    // protected anchor cannot participate in the
                                    // duplicate merge. Retry when its send record
                                    // clears and use the original destination.
                                    blockedByProtectedConversation = true
                                    return
                                }
                                let created = try ConversationFactory.create(
                                    for: makeConversationIdentity(from: identity),
                                    initialLastMessageDate: message.internalDate,
                                    initialSnippet: message.conversationPreviewText,
                                    initialInboxSeed: ConversationInboxSeed(
                                        isInboxArrival: (message.labels ?? []).contains { $0.id == "INBOX" },
                                        isUnread: message.isUnread,
                                        messageDate: message.internalDate
                                    ),
                                    in: context
                                )
                                // Permanent ID now: temporary IDs recorded in maps and
                                // touched sets would go stale at an interim save.
                                try context.obtainPermanentIDs(for: [created])
                                if let source, let archivedAt = source.archivedAt {
                                    // Rollup intentionally preserves the current
                                    // state for sent-only/latest-outgoing chats. A
                                    // replacement for an archived source must begin
                                    // archived or old sent mail resurfaces.
                                    created.archivedAt = archivedAt
                                    created.hidden = source.hidden
                                }
                                createdDestinationIDs.insert(created.objectID)
                                destinationByHash[identity.participantHash] = created
                                destination = created
                            }
                        }

                        if let previous = source {
                            if createdDestinationIDs.contains(destination.objectID),
                               previous.archivedAt == nil {
                                // Active wins when a newly created destination
                                // combines rows from active and archived sources.
                                destination.archivedAt = nil
                                destination.hidden = false
                            }
                            touchedConversationIDs.insert(previous.objectID)
                            touchedThisBatch.insert(previous)
                            lastDestinationBySource[previous.objectID] = destination.objectID

                            message.conversation = destination

                            // Transfer user state before the next interim save. A
                            // drained stale shell cannot become a later destination,
                            // so the state follows the content that emptied it.
                            if (previous.messages ?? []).isEmpty,
                               !pendingSendConversationIds.contains(previous.id) {
                                destination.pinned = destination.pinned || previous.pinned
                                destination.muted = destination.muted || previous.muted
                                previous.pinned = false
                                previous.muted = false
                                drainedSourceIDs.insert(previous.objectID)
                            }
                        } else {
                            message.conversation = destination
                        }
                        touchedConversationIDs.insert(destination.objectID)
                        participantRowRepairCandidateIDs.insert(destination.objectID)
                        touchedThisBatch.insert(destination)
                        movedCount += 1
                    } catch {
                        processingError = error
                    }
                }

                if let processingError {
                    Log.error(
                        "Participant-set re-home failed while processing message",
                        category: .coreData,
                        error: processingError
                    )
                    context.rollback()
                    return nil
                }

                processed += 1
                if processed % 500 == 0 {
                    if !touchedThisBatch.isEmpty {
                        // Roll up before each interim save so no published row carries
                        // stale unread counts; the final pass recomputes everything.
                        for conversation in touchedThisBatch where !conversation.isDeleted {
                            conversationManager.updateConversationRollups(for: conversation, myEmail: myEmail)
                        }
                    }
                    if context.hasChanges {
                        guard coreDataStack.saveIfNeeded(
                            context: context,
                            caller: "DataCleanupService.rehomeMessagesByParticipantSet.interim"
                        ) else {
                            context.rollback()
                            return nil
                        }
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
            guard coreDataStack.saveIfNeeded(
                context: context,
                caller: "DataCleanupService.rehomeMessagesByParticipantSet.final"
            ) else {
                context.rollback()
                return nil
            }

            if movedCount > 0 {
                Log.info("Participant-set split re-homed \(movedCount) message(s) across \(touchedConversationIDs.count) conversation(s)", category: .coreData)
            }
            return RehomeResult(
                touchedConversationIDs: touchedConversationIDs,
                participantRowRepairCandidateIDs: participantRowRepairCandidateIDs,
                lastDestinationBySource: lastDestinationBySource,
                blockedByProtectedConversation: blockedByProtectedConversation
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
        excluding excludedObjectIDs: Set<NSManagedObjectID>,
        excludingConversationIDs: Set<UUID>,
        in context: NSManagedObjectContext
    ) throws -> (conversation: Conversation?, hasProtectedCandidate: Bool) {
        let request = Conversation.fetchRequest()
        request.predicate = NSPredicate(format: "participantHash == %@", participantHash)
        request.includesPendingChanges = true

        let fetched = try context.fetch(request)
        let viable = fetched.filter { !excludedObjectIDs.contains($0.objectID) }
        let selection = viable.isEmpty ? nil : ConversationRoutingPolicy()
            .selectParticipantHashConversation(
                from: viable,
                reactivateArchivedIfNeeded: true
            )
        guard let selection else { return (nil, false) }
        guard !excludingConversationIDs.contains(selection.id) else {
            return (nil, true)
        }
        return (selection, false)
    }

    /// Phase 2a: deletes conversations the re-home emptied after all message moves
    /// and their interim saves have completed.
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
    ) async -> Bool {
        let result: (deletedObjectIDs: [NSManagedObjectID], succeeded: Bool) = await context.perform { [self] in
            // Conversations referenced by in-flight optimistic sends must survive
            // even when they look empty here: their optimistic message may be
            // unsaved on the view context and invisible to this background context.
            let pendingSendConversationIds: Set<UUID>
            let pendingActionsByConversationID: [UUID: [PendingAction]]
            do {
                pendingSendConversationIds = try pendingSendConversationIDs(in: context)
                pendingActionsByConversationID = try PendingAction.referencesByConversationID(
                    in: context
                )
            } catch {
                Log.error(
                    "Failed to fetch protected references before emptied-conversation sweep",
                    category: .coreData,
                    error: error
                )
                return ([], false)
            }

            let request = Conversation.fetchRequest()
            request.predicate = NSPredicate(format: "messages.@count == 0")
            let emptyConversations: [Conversation]
            do {
                emptyConversations = try context.fetch(request)
            } catch {
                Log.error(
                    "Failed to fetch emptied conversations for participant-set sweep",
                    category: .coreData,
                    error: error
                )
                return ([], false)
            }
            let creationGrace: TimeInterval = 60 * 60

            var deleted: [NSManagedObjectID] = []
            for conversation in emptyConversations {
                guard !pendingSendConversationIds.contains(conversation.id) else { continue }
                let knownDestinationID = lastDestinationBySource[conversation.objectID]
                if knownDestinationID == nil,
                   let createdAt = conversation.createdAt,
                   Date().timeIntervalSince(createdAt) < creationGrace {
                    continue
                }

                let referencedActions = pendingActionsByConversationID[conversation.id] ?? []
                let knownDestination = knownDestinationID.flatMap {
                    try? context.existingObject(with: $0) as? Conversation
                }
                if !referencedActions.isEmpty {
                    guard let knownDestination, !knownDestination.isDeleted else {
                        // A prior interrupted run may leave no reconstructable
                        // source-to-destination map. Keep its hidden shell so a
                        // still-live queued action is never orphaned as debris.
                        ConversationRollupSnapshot.make(from: []).apply(to: conversation)
                        continue
                    }
                    for action in referencedActions {
                        action.conversationId = knownDestination.id
                    }
                }

                // Never discard conversation-level user state. A fully-drained
                // shell can transfer it only when this run knows where its
                // messages went. After a crash, the retry may see the persisted
                // empty shell but have no source-to-destination map; retain that
                // shell instead of silently losing pin/mute state.
                if conversation.pinned || conversation.muted {
                    guard let destination = knownDestination,
                          !destination.isDeleted else {
                        ConversationRollupSnapshot.make(from: []).apply(to: conversation)
                        continue
                    }
                    destination.pinned = destination.pinned || conversation.pinned
                    destination.muted = destination.muted || conversation.muted
                }

                deleted.append(conversation.objectID)
                context.delete(conversation)
            }

            if !deleted.isEmpty || context.hasChanges {
                guard coreDataStack.saveIfNeeded(
                    context: context,
                    caller: "DataCleanupService.deleteEmptiedConversations"
                ) else {
                    context.rollback()
                    return ([], false)
                }
            }
            return (deleted, true)
        }

        guard result.succeeded else { return false }
        let deletedObjectIDs = result.deletedObjectIDs
        if !deletedObjectIDs.isEmpty {
            NSManagedObjectContext.mergeChanges(
                fromRemoteContextSave: [NSDeletedObjectsKey: deletedObjectIDs],
                into: [coreDataStack.viewContext]
            )
            Log.info("Participant-set split removed \(deletedObjectIDs.count) emptied conversation shell(s)", category: .coreData)
        }
        return true
    }

    /// Phase 2c: conversations that kept their hash through the re-home can still
    /// carry participant rows from their thread-merged past. Replies address the
    /// conversation's participant rows, and the maintenance hash-fix pass
    /// recomputes hashes FROM those rows, so stale rows would send replies to the
    /// wrong people and fight the router. Rebuild rows from message-derived
    /// identity wherever they diverge.
    private func rebuildParticipantRowsForRehomedConversations(
        candidateIDs: Set<NSManagedObjectID>,
        myAliases: Set<String>,
        in context: NSManagedObjectContext
    ) async -> Bool {
        await context.perform {
            var rebuiltCount = 0

            for objectID in candidateIDs {
                guard let conversation = try? context.existingObject(with: objectID) as? Conversation,
                      !conversation.isDeleted,
                      let conversationHash = conversation.participantHash else { continue }

                // List conversations share their "l|" hash across messages
                // whose participant sets differ, so no single message defines
                // the expected rows — a rebuild would copy whichever message
                // the unordered relationship yields first. Their rows seed
                // once at creation and stay put.
                if conversation.conversationType == .list { continue }

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
                let rowsNeedRepair = expected != current
                let typeNeedsRepair = conversation.conversationType != identity.type
                guard rowsNeedRepair || typeNeedsRepair else { continue }

                if rowsNeedRepair {
                    for row in conversation.participants ?? [] {
                        context.delete(row)
                    }
                    do {
                        for email in identity.participants {
                            let person = try PersonFactory.findOrCreate(
                                email: email,
                                displayName: nil,
                                in: context
                            )
                            _ = try ConversationFactory.createParticipant(
                                person: person,
                                conversation: conversation,
                                role: .normal,
                                in: context
                            )
                        }
                    } catch {
                        Log.error(
                            "Failed to rebuild participant rows after participant-set split",
                            category: .coreData,
                            error: error
                        )
                        context.rollback()
                        return false
                    }
                }
                conversation.conversationType = identity.type
                rebuiltCount += 1
            }

            if rebuiltCount > 0 {
                guard self.coreDataStack.saveIfNeeded(
                    context: context,
                    caller: "DataCleanupService.rebuildParticipantRowsForRehomedConversations"
                ) else {
                    context.rollback()
                    return false
                }
                Log.info("Rebuilt participant rows for \(rebuiltCount) conversation(s) after participant-set split", category: .coreData)
            }
            return true
        }
    }

    private func conversationNeedsParticipantRowRepair(
        _ conversation: Conversation,
        identity: ParticipantSetIdentity
    ) -> Bool {
        // List rows are seeded from list metadata rather than one arbitrary
        // message and are intentionally not rebuilt by Phase 2c.
        guard conversation.conversationType != .list else { return false }
        let expected = Set(identity.participants)
        let current = Set(
            (conversation.participants ?? []).compactMap { $0.person }.map { normalizedEmail($0.email) }
        )
        return expected != current || conversation.conversationType != identity.type
    }

    /// Returns the HME/self-filtered identity only when the source rows are
    /// internally consistent with the source's stored hash. This makes legacy
    /// one-From-row stores conservative without rejecting known self/HME repair.
    private func validatedConversationIdentity(
        _ conversation: Conversation,
        myAliases: Set<String>
    ) -> ParticipantSetIdentity? {
        let rows = Array(conversation.participants ?? [])
        guard !rows.isEmpty,
              !rows.contains(where: { $0.participantRole == .listAddress }) else {
            return nil
        }

        var rawEmails = Set<String>()
        var withoutHideMyEmail = Set<String>()
        for row in rows {
            guard let person = row.person else { return nil }
            let email = normalizedEmail(person.email)
            guard !email.isEmpty else { return nil }
            rawEmails.insert(email)
            if !EmailNormalizer.isHideMyEmailDisplayName(person.displayName) {
                withoutHideMyEmail.insert(email)
            }
        }

        let rawHash = calculateParticipantHash(from: Array(rawEmails))
        let selfFilteredIdentity = makeParticipantSetIdentity(
            normalizedEmails: rawEmails,
            myAliases: myAliases
        )
        let repairedIdentity = makeParticipantSetIdentity(
            normalizedEmails: withoutHideMyEmail,
            myAliases: myAliases
        )
        let sourceHash = conversation.participantHash?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard sourceHash == rawHash ||
                sourceHash == selfFilteredIdentity.participantHash ||
                sourceHash == repairedIdentity.participantHash else {
            return nil
        }
        return repairedIdentity
    }
}
