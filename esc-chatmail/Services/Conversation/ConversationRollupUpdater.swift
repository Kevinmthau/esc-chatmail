import Foundation
import CoreData

struct ConversationPreviewRepairResult: Sendable {
    let repairedCount: Int
    let didDrain: Bool
}

/// Handles updating conversation rollup data (lastMessageDate, snippet, hasInbox, etc.)
/// Extracted from ConversationManager for focused responsibility.
/// Struct is naturally Sendable since it only holds immutable references.
struct ConversationRollupUpdater: Sendable {
    private let coreDataStack: CoreDataStack
    /// A conversation with more stored messages than this is rolled up from
    /// bounded queries (`ConversationRollupBoundedReader`). A test passes 0
    /// to send every stored conversation that way.
    private let boundedRollupThreshold: Int

    init(
        coreDataStack: CoreDataStack = .shared,
        boundedRollupThreshold: Int = ConversationRollupBoundedReader.messageCountThreshold
    ) {
        self.coreDataStack = coreDataStack
        self.boundedRollupThreshold = boundedRollupThreshold
    }

    // MARK: - Single Conversation Rollup

    /// Updates rollup data for a conversation. Must be called from within the conversation's context queue.
    /// - Parameters:
    ///   - conversation: The conversation to update
    ///   - myEmail: The current user's email (must be captured before entering context.perform block)
    func updateRollups(for conversation: Conversation, myEmail: String) {
        guard let context = conversation.managedObjectContext else { return }
        updateRollups(
            for: conversation,
            myEmail: myEmail,
            normalizedSelfAddresses: Self.storedSelfAddresses(in: context, myEmail: myEmail)
        )
    }

    /// `updateRollups(for:myEmail:)` for several conversations of one context,
    /// reading the account's addresses once and not once per conversation.
    /// Must be called on `context`'s queue. For a synchronous caller that
    /// already holds the queue and its own save (the participant-set re-home
    /// migration, which rolls up thousands of conversations).
    func updateRollups(
        for conversations: some Sequence<Conversation>,
        in context: NSManagedObjectContext,
        myEmail: String
    ) {
        let selfAddresses = Self.storedSelfAddresses(in: context, myEmail: myEmail)
        for conversation in conversations {
            updateRollups(for: conversation, myEmail: myEmail, normalizedSelfAddresses: selfAddresses)
        }
    }

    /// `updateRollups(for:myEmail:)` for a batch, which reads the account's
    /// addresses once (`storedSelfAddresses`) and not once per conversation.
    private func updateRollups(
        for conversation: Conversation,
        myEmail: String,
        normalizedSelfAddresses: Set<String>
    ) {
        guard conversation.managedObjectContext != nil else { return }
        let messages = conversation.messages ?? []
        let snapshot = ConversationRollupSnapshot.make(from: messages)
        logRollupSnapshot(snapshot, for: conversation, totalCount: messages.count)
        snapshot.apply(to: conversation)

        updateDisplayNameOnly(
            for: conversation,
            myEmail: myEmail,
            normalizedSelfAddresses: normalizedSelfAddresses,
            senders: { .walking(messages) }
        )
    }

    /// The rollup of a large conversation, read with bounded queries and the
    /// context's unsaved messages (`ConversationRollupBoundedReader`). A read
    /// that fails walks the conversation as `updateRollups` does: a partial
    /// answer is never applied.
    private func updateBoundedRollups(
        for conversation: Conversation,
        overlay: ConversationRollupBoundedReader.Overlay?,
        storedMessageCount: Int,
        myEmail: String,
        normalizedSelfAddresses: Set<String>,
        in context: NSManagedObjectContext
    ) {
        let snapshot: ConversationRollupSnapshot
        do {
            snapshot = try ConversationRollupBoundedReader.snapshot(of: conversation, overlay: overlay, in: context)
        } catch {
            Log.error("Bounded rollup read failed; walking the conversation", category: .conversation, error: error)
            updateRollups(for: conversation, myEmail: myEmail, normalizedSelfAddresses: normalizedSelfAddresses)
            return
        }
        logRollupSnapshot(snapshot, for: conversation, totalCount: storedMessageCount)
        snapshot.apply(to: conversation)

        updateDisplayNameOnly(
            for: conversation,
            myEmail: myEmail,
            normalizedSelfAddresses: normalizedSelfAddresses,
            senders: { Self.boundedSenders(of: conversation, overlay: overlay, in: context) }
        )
    }

    /// The bounded reader's senders, or a walk of the messages when its read
    /// failed.
    private static func boundedSenders(
        of conversation: Conversation,
        overlay: ConversationRollupBoundedReader.Overlay?,
        in context: NSManagedObjectContext
    ) -> ConversationSenderSummary {
        do {
            return try ConversationRollupBoundedReader.senders(of: conversation, overlay: overlay, in: context)
        } catch {
            Log.error("Bounded sender read failed; walking the conversation", category: .conversation, error: error)
            return .walking(conversation.messages ?? [])
        }
    }

    /// Splits `conversationIDs` into the conversations to walk and those the
    /// bounded reader rolls up, with their stored message counts. A
    /// conversation with no stored row (a temporary ID) has all its messages
    /// in memory and is walked; a failed count walks every one. Call on the
    /// context's queue.
    private func partitionForRollup(
        _ conversationIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext
    ) -> (walked: Set<NSManagedObjectID>, bounded: [NSManagedObjectID: Int]) {
        let permanentIDs = conversationIDs.filter { !$0.isTemporaryID }
        guard !permanentIDs.isEmpty, ConversationRollupBoundedReader.supportsBoundedReads(in: context) else {
            return (conversationIDs, [:])
        }
        let counts: [NSManagedObjectID: Int]
        do {
            counts = try ConversationRollupBoundedReader.storedMessageCounts(of: Array(permanentIDs), in: context)
        } catch {
            Log.error("Failed to count conversation messages for rollups; walking each", category: .conversation, error: error)
            return (conversationIDs, [:])
        }
        let bounded = counts.filter { $0.value > boundedRollupThreshold }
        return (conversationIDs.subtracting(bounded.keys), bounded)
    }

    /// The signed-in account's own addresses, normalized: `myEmail`, and the
    /// stored `Account` row's address and send-as aliases. Must be called on
    /// `context`'s queue.
    ///
    /// The loaded title leaves out every one of the user's addresses
    /// (`ConversationParticipantExtractor.extractNonMeParticipants`, given
    /// `AliasManager`'s set); the stored title left out `myEmail` alone, so a
    /// group holding a participant row for one of the user's send-as aliases
    /// was stored with the user's own name in it, and the row's title changed
    /// when its participants loaded. This is `AliasManager`'s set without the
    /// addresses it adds from the user's Contacts card: the stored title reads
    /// nothing from Contacts, whose access can arrive or go at any time. A
    /// failed read leaves `myEmail` alone, which is what was excluded before.
    static func storedSelfAddresses(
        in context: NSManagedObjectContext,
        myEmail: String
    ) -> Set<String> {
        var rawAddresses = [myEmail]
        let request = Account.fetchRequest()
        request.fetchLimit = 1
        do {
            if let account = try context.fetch(request).first {
                rawAddresses.append(account.email)
                rawAddresses.append(contentsOf: account.aliasesArray)
            }
        } catch {
            Log.error("Failed to read the account's aliases for a stored title", category: .conversation, error: error)
        }
        return ConversationParticipantExtractor.normalizedAliasSet(from: rawAddresses)
    }

    // MARK: - Batch Rollup Operations

    /// Updates rollups for ALL conversations - expensive O(n*m) operation.
    /// Prefer updateRollupsForModified when possible.
    @MainActor
    func updateAllRollups(
        in context: NSManagedObjectContext,
        myEmail: String
    ) async {
        await context.perform {
            let request = Conversation.fetchRequest()
            request.fetchBatchSize = 50
            // Prefetch relationships to avoid N+1 queries when accessing messages/labels/participants
            request.relationshipKeyPathsForPrefetching = [
                "messages",
                "messages.labels",
                "participants",
                "participants.person"
            ]

            let conversations: [Conversation]
            do {
                conversations = try context.fetch(request)
            } catch {
                Log.error("Failed to fetch conversations for rollup update", category: .conversation, error: error)
                return
            }

            let selfAddresses = Self.storedSelfAddresses(in: context, myEmail: myEmail)
            for conversation in conversations {
                self.updateRollups(for: conversation, myEmail: myEmail, normalizedSelfAddresses: selfAddresses)
            }
        }
    }

    /// Updates rollups only for conversations that were modified.
    /// Much more efficient than updateAllRollups - O(k*m) where k << n.
    @MainActor
    @discardableResult
    func updateRollupsForModified(
        conversationIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext,
        myEmail: String
    ) async -> Bool {
        guard !conversationIDs.isEmpty else { return true }

        return await context.perform {
            // A conversation over the threshold is rolled up from bounded
            // queries (`ConversationRollupBoundedReader`); the rest are walked
            // with their messages and labels prefetched, as before. Until
            // 2026-11-28 every touched conversation was walked, every row and
            // its body text loaded (architecture review 2026-11, data-model#4).
            let (walkedIDs, boundedCounts) = self.partitionForRollup(conversationIDs, in: context)

            let walkedRequest = Conversation.fetchRequest()
            walkedRequest.predicate = NSPredicate(format: "SELF IN %@", walkedIDs)
            walkedRequest.relationshipKeyPathsForPrefetching = [
                "messages",
                "messages.labels",
                "participants",
                "participants.person"
            ]
            let boundedRequest = Conversation.fetchRequest()
            boundedRequest.predicate = NSPredicate(format: "SELF IN %@", Array(boundedCounts.keys))
            boundedRequest.relationshipKeyPathsForPrefetching = ["participants", "participants.person"]

            let walked: [Conversation]
            let bounded: [Conversation]
            do {
                walked = walkedIDs.isEmpty ? [] : try context.fetch(walkedRequest)
                bounded = boundedCounts.isEmpty ? [] : try context.fetch(boundedRequest)
            } catch {
                Log.error("Failed to batch fetch conversations for rollup update", category: .conversation, error: error)
                return false
            }

            let selfAddresses = Self.storedSelfAddresses(in: context, myEmail: myEmail)
            for conversation in walked {
                self.updateRollups(for: conversation, myEmail: myEmail, normalizedSelfAddresses: selfAddresses)
            }
            let overlays = bounded.isEmpty ? [:] : ConversationRollupBoundedReader.overlays(in: context)
            for conversation in bounded {
                self.updateBoundedRollups(
                    for: conversation,
                    overlay: overlays[conversation.objectID],
                    storedMessageCount: boundedCounts[conversation.objectID] ?? 0,
                    myEmail: myEmail,
                    normalizedSelfAddresses: selfAddresses,
                    in: context
                )
            }
            return true
        }
    }

    /// Updates rollups for conversations by keyHash.
    @MainActor
    func updateRollupsForConversations(
        keyHashes: Set<String>,
        in context: NSManagedObjectContext,
        myEmail: String
    ) async {
        guard !keyHashes.isEmpty else { return }

        await context.perform {
            let request = Conversation.fetchRequest()
            request.predicate = ConversationPredicates.keyHashes(Array(keyHashes))
            request.fetchBatchSize = 50
            // Prefetch relationships to avoid N+1 queries when accessing messages/labels/participants
            request.relationshipKeyPathsForPrefetching = [
                "messages",
                "messages.labels",
                "participants",
                "participants.person"
            ]

            let conversations: [Conversation]
            do {
                conversations = try context.fetch(request)
            } catch {
                Log.error("Failed to fetch conversations by keyHash for rollup update", category: .conversation, error: error)
                return
            }

            let selfAddresses = Self.storedSelfAddresses(in: context, myEmail: myEmail)
            for conversation in conversations {
                self.updateRollups(for: conversation, myEmail: myEmail, normalizedSelfAddresses: selfAddresses)
            }
        }
    }

    /// How long an active conversation may exist without any persisted messages
    /// before the repair pass treats it as a stranded shell.
    /// Conversation rows are created and saved before their first message persists
    /// (ConversationCreationSerializer saves immediately to prevent duplicates), so a
    /// generous grace period shields shells whose message is still in flight — an
    /// optimistic send that has not committed yet, or a sync page that has not saved.
    /// The grace is keyed to createdAt, not just lastMessageDate: sync-created shells
    /// carry the message's historical internalDate as lastMessageDate, which can be
    /// arbitrarily old the moment the shell is saved. Legacy rows without createdAt
    /// fall back to the lastMessageDate cutoff alone.
    static let messagelessConversationGracePeriod: TimeInterval = 60 * 60

    /// Archives active conversations that advertise activity (lastMessageDate) but
    /// have no messages in the store — shells left behind when a conversation was
    /// created and saved for a message that then failed to persist. These rows sit
    /// in the list forever showing a timestamp with no preview: rollups never run
    /// for them (only successful message writes track a conversation as modified),
    /// the preview repair skips them (it requires a message with content), and the
    /// user cannot archive them (archiveConversation early-returns on empty
    /// conversations). Applying the empty rollup snapshot clears the stale metadata
    /// and archives + hides the row, matching how rollups already treat a
    /// conversation whose last message is deleted.
    /// - Returns: The number of conversations archived.
    @MainActor
    func archiveMessagelessConversations(
        in context: NSManagedObjectContext,
        olderThan cutoff: Date,
        excludingConversationIDs: Set<UUID> = []
    ) async -> Int {
        await context.perform {
            let request = Conversation.fetchRequest()
            // createdAt shields shells created moments ago whose lastMessageDate is
            // historical (sync sets it to the message's internalDate); rows predating
            // the createdAt attribute rely on the lastMessageDate cutoff alone.
            let strandedShellPredicate = NSPredicate(
                format: """
                archivedAt == nil AND lastMessageDate != nil AND lastMessageDate < %@ \
                AND (createdAt == nil OR createdAt < %@) AND messages.@count == 0
                """,
                cutoff as NSDate,
                cutoff as NSDate
            )
            if excludingConversationIDs.isEmpty {
                request.predicate = strandedShellPredicate
            } else {
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    strandedShellPredicate,
                    NSPredicate(
                        format: "NOT (id IN %@)",
                        Array(excludingConversationIDs) as NSArray
                    )
                ])
            }
            request.fetchBatchSize = 50

            let conversations: [Conversation]
            do {
                conversations = try context.fetch(request)
            } catch {
                Log.error("Failed to fetch message-less conversations for repair", category: .conversation, error: error)
                return 0
            }

            guard !conversations.isEmpty else { return 0 }

            let emptySnapshot = ConversationRollupSnapshot.make(from: [])
            for conversation in conversations {
                emptySnapshot.apply(to: conversation)
            }
            return conversations.count
        }
    }

    /// Repairs active conversations that have a last-message date but no stored
    /// row preview by deriving the preview from their current visible messages.
    @MainActor
    func repairMissingConversationPreviews(
        in context: NSManagedObjectContext,
        limit: Int = 200
    ) async -> ConversationPreviewRepairResult {
        guard limit > 0 else {
            return ConversationPreviewRepairResult(repairedCount: 0, didDrain: false)
        }

        return await context.perform {
            var repairedCount = 0
            let chunkSize = 50
            var fetchOffset = 0

            while repairedCount < limit {
                let candidateIDs: [NSManagedObjectID]
                do {
                    candidateIDs = try self.fetchConversationPreviewRepairCandidateIDs(
                        in: context,
                        fetchLimit: chunkSize,
                        fetchOffset: fetchOffset
                    )
                } catch {
                    Log.error("Failed to fetch conversations for preview repair", category: .conversation, error: error)
                    return ConversationPreviewRepairResult(repairedCount: repairedCount, didDrain: false)
                }

                guard !candidateIDs.isEmpty else {
                    return ConversationPreviewRepairResult(repairedCount: repairedCount, didDrain: true)
                }
                fetchOffset += candidateIDs.count

                let conversations: [Conversation]
                do {
                    conversations = try self.fetchConversationPreviewRepairCandidates(
                        objectIDs: candidateIDs,
                        in: context
                    )
                } catch {
                    Log.error("Failed to fetch conversation repair chunk", category: .conversation, error: error)
                    return ConversationPreviewRepairResult(repairedCount: repairedCount, didDrain: false)
                }

                let conversationsByID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.objectID, $0) })
                for objectID in candidateIDs {
                    guard repairedCount < limit else { break }
                    guard let conversation = conversationsByID[objectID] else { continue }
                    context.refresh(conversation, mergeChanges: false)

                    guard MessagePreviewText.nonEmpty(conversation.snippet) == nil,
                          let messages = conversation.messages else {
                        continue
                    }

                    let snapshot = ConversationRollupSnapshot.make(from: messages)
                    guard snapshot.lastMessageDate != nil,
                          let previewText = MessagePreviewText.nonEmpty(snapshot.snippet) else {
                        continue
                    }

                    conversation.snippet = previewText
                    repairedCount += 1
                }
            }

            return ConversationPreviewRepairResult(repairedCount: repairedCount, didDrain: false)
        }
    }

    private func fetchConversationPreviewRepairCandidateIDs(
        in context: NSManagedObjectContext,
        fetchLimit: Int,
        fetchOffset: Int
    ) throws -> [NSManagedObjectID] {
        let whitespacePattern = #"^\s+$"#
        let request = NSFetchRequest<NSManagedObjectID>(entityName: "Conversation")
        request.resultType = .managedObjectIDResultType
        request.includesPendingChanges = false
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(
                format: "archivedAt == nil AND lastMessageDate != nil AND (snippet == nil OR snippet == '' OR snippet MATCHES %@)",
                whitespacePattern
            ),
            NSPredicate(
                format: """
                SUBQUERY(messages, $message,
                    SUBQUERY($message.labels, $label, $label.id IN %@).@count == 0 AND (
                        ($message.cleanedSnippet != nil AND $message.cleanedSnippet != '' AND NOT ($message.cleanedSnippet MATCHES %@)) OR
                        ($message.chatPreviewText != nil AND $message.chatPreviewText != '' AND NOT ($message.chatPreviewText MATCHES %@)) OR
                        ($message.snippet != nil AND $message.snippet != '' AND NOT ($message.snippet MATCHES %@)) OR
                        ($message.subject != nil AND $message.subject != '' AND NOT ($message.subject MATCHES %@))
                    )
                ).@count > 0
                """,
                Array(MessagePersister.excludedMailboxLabelIDs),
                whitespacePattern,
                whitespacePattern,
                whitespacePattern,
                whitespacePattern
            )
        ])
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Conversation.lastMessageDate, ascending: false)
        ]
        request.fetchLimit = fetchLimit
        request.fetchOffset = fetchOffset
        request.fetchBatchSize = fetchLimit

        return try context.fetch(request)
    }

    private func fetchConversationPreviewRepairCandidates(
        objectIDs: [NSManagedObjectID],
        in context: NSManagedObjectContext
    ) throws -> [Conversation] {
        guard !objectIDs.isEmpty else { return [] }

        let request = Conversation.fetchRequest()
        request.predicate = NSPredicate(format: "SELF IN %@", objectIDs)
        request.fetchBatchSize = objectIDs.count
        request.relationshipKeyPathsForPrefetching = ["messages", "messages.labels"]

        return try context.fetch(request)
    }

    /// Refreshes stored conversation display names without recomputing any other rollup fields.
    @MainActor
    func updateDisplayNamesForAllConversations(
        in context: NSManagedObjectContext,
        myEmail: String
    ) async {
        await context.perform {
            let request = Conversation.fetchRequest()
            request.fetchBatchSize = 50
            request.relationshipKeyPathsForPrefetching = [
                "messages",
                "participants",
                "participants.person"
            ]

            let conversations: [Conversation]
            do {
                conversations = try context.fetch(request)
            } catch {
                Log.error("Failed to fetch conversations for display-name refresh", category: .conversation, error: error)
                return
            }

            let selfAddresses = Self.storedSelfAddresses(in: context, myEmail: myEmail)
            for conversation in conversations {
                self.updateDisplayNameOnly(
                    for: conversation,
                    myEmail: myEmail,
                    normalizedSelfAddresses: selfAddresses,
                    senders: { .walking(conversation.messages ?? []) }
                )
            }
        }
    }

    /// Refreshes stored display names for selected conversations without recomputing rollups.
    /// - Returns: false when the conversation fetch failed, so a caller that
    ///   latches a one-shot flag can leave it clear instead of reading the
    ///   failure as "nothing to refresh".
    @MainActor
    @discardableResult
    func updateDisplayNamesForConversations(
        conversationIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext,
        myEmail: String
    ) async -> Bool {
        guard !conversationIDs.isEmpty else { return true }

        return await context.perform {
            // A large conversation's senders come from a grouped query, as for
            // its rollup; the rest walk their prefetched messages.
            let (walkedIDs, boundedCounts) = self.partitionForRollup(conversationIDs, in: context)
            let walkedRequest = Conversation.fetchRequest()
            walkedRequest.predicate = NSPredicate(format: "SELF IN %@", walkedIDs)
            walkedRequest.relationshipKeyPathsForPrefetching = [
                "messages",
                "participants",
                "participants.person"
            ]
            let boundedRequest = Conversation.fetchRequest()
            boundedRequest.predicate = NSPredicate(format: "SELF IN %@", Array(boundedCounts.keys))
            boundedRequest.relationshipKeyPathsForPrefetching = ["participants", "participants.person"]

            let walked: [Conversation]
            let bounded: [Conversation]
            do {
                walked = walkedIDs.isEmpty ? [] : try context.fetch(walkedRequest)
                bounded = boundedCounts.isEmpty ? [] : try context.fetch(boundedRequest)
            } catch {
                Log.error("Failed to fetch conversations for display-name update", category: .conversation, error: error)
                return false
            }

            let selfAddresses = Self.storedSelfAddresses(in: context, myEmail: myEmail)
            for conversation in walked {
                self.updateDisplayNameOnly(
                    for: conversation,
                    myEmail: myEmail,
                    normalizedSelfAddresses: selfAddresses,
                    senders: { .walking(conversation.messages ?? []) }
                )
            }
            let overlays = bounded.isEmpty ? [:] : ConversationRollupBoundedReader.overlays(in: context)
            for conversation in bounded {
                let overlay = overlays[conversation.objectID]
                self.updateDisplayNameOnly(
                    for: conversation,
                    myEmail: myEmail,
                    normalizedSelfAddresses: selfAddresses,
                    senders: { Self.boundedSenders(of: conversation, overlay: overlay, in: context) }
                )
            }
            return true
        }
    }

    /// Re-derives titles for list conversations whose stored display name is
    /// identifier-derived. Runs every launch rather than as a one-shot
    /// migration: a `ParsedListId` heuristic improvement then heals titles
    /// stored under the old heuristic at the next launch, with no
    /// `hasRefreshedConversationNames` key bump — the Brevo `mailin.fr` fix
    /// shipped without one, so its stale tokens stayed on screen until each
    /// list's next arrival happened to re-run rollups.
    ///
    /// Two-phase on purpose: the candidate scan reads attributes only (no
    /// relationship faults), and the message/participant walk inside
    /// `updateDisplayNameOnly` runs just for the conversations whose stored
    /// title the current heuristic recognizes as machine metadata — typically
    /// zero, so the steady-state launch cost is one small fetch.
    /// - Returns: The number of conversations whose stored title changed, or
    ///   nil when a fetch failed — the caller must not treat a failed scan as
    ///   "no candidates" (it would latch its per-launch completion guard and
    ///   skip the repair for the rest of the process).
    @MainActor
    func repairIdentifierDerivedListConversationTitles(
        in context: NSManagedObjectContext,
        myEmail: String
    ) async -> Int? {
        await context.perform { () -> Int? in
            let scanRequest = Conversation.fetchRequest()
            scanRequest.predicate = ConversationPredicates.hasListId
            scanRequest.returnsObjectsAsFaults = false
            scanRequest.fetchBatchSize = 100

            let listConversations: [Conversation]
            do {
                listConversations = try context.fetch(scanRequest)
            } catch {
                Log.error("Failed to fetch list conversations for title repair", category: .conversation, error: error)
                return nil
            }

            let candidateIDs = listConversations
                .filter { conversation in
                    ParsedListId.isIdentifierDerivedDisplayTitle(
                        conversation.displayName,
                        listId: conversation.listId
                    )
                }
                .map(\.objectID)
            guard !candidateIDs.isEmpty else { return 0 }

            // Refetch just the candidates with relationships prefetched so
            // the sender walk does not fire per-object faults.
            let repairRequest = Conversation.fetchRequest()
            repairRequest.predicate = NSPredicate(format: "SELF IN %@", candidateIDs)
            repairRequest.relationshipKeyPathsForPrefetching = [
                "messages",
                "participants",
                "participants.person"
            ]

            let candidates: [Conversation]
            do {
                candidates = try context.fetch(repairRequest)
            } catch {
                Log.error("Failed to fetch list-title repair candidates", category: .conversation, error: error)
                return nil
            }

            var repairedCount = 0
            let selfAddresses = Self.storedSelfAddresses(in: context, myEmail: myEmail)
            for conversation in candidates {
                let titleBefore = conversation.displayName
                self.updateDisplayNameOnly(
                    for: conversation,
                    myEmail: myEmail,
                    normalizedSelfAddresses: selfAddresses,
                    senders: { .walking(conversation.messages ?? []) }
                )
                if conversation.displayName != titleBefore {
                    repairedCount += 1
                }
            }
            return repairedCount
        }
    }

    // MARK: - Private Helper Methods

    private func logRollupSnapshot(
        _ snapshot: ConversationRollupSnapshot,
        for conversation: Conversation,
        totalCount: Int
    ) {
        Log.diagnostic(
            .conversationRollups,
            "Conversation \(conversation.id.uuidString): hasInbox=\(snapshot.hasInbox), unread=\(snapshot.inboxUnreadCount), totalMsgCount=\(totalCount), hidden=\(conversation.hidden)",
            category: .conversation
        )
    }

    /// Updates only the stored display name from participants, excluding the current user.
    func updateDisplayNameOnly(for conversation: Conversation, myEmail: String) {
        updateDisplayNameOnly(
            for: conversation,
            myEmail: myEmail,
            normalizedSelfAddresses: conversation.managedObjectContext.map {
                Self.storedSelfAddresses(in: $0, myEmail: myEmail)
            } ?? ConversationParticipantExtractor.normalizedAliasSet(from: [myEmail]),
            senders: { .walking(conversation.messages ?? []) }
        )
    }

    /// `senders` is asked at most once, and only where the title needs the
    /// messages' From names: a list conversation that keeps its stored title
    /// reads no message at all. A walk passes `.walking(messages)`, a large
    /// conversation the bounded reader's grouped query.
    private func updateDisplayNameOnly(
        for conversation: Conversation,
        myEmail: String,
        normalizedSelfAddresses: Set<String>,
        senders: () -> ConversationSenderSummary
    ) {
        guard let participants = conversation.participants else { return }

        let normalizedMyEmail = EmailNormalizer.normalize(myEmail)

        // The rows a title can name, in display order. Filtered once, so the
        // check below and the walk that builds the title cannot come to
        // disagree about which rows count.
        //
        // In display order, never as the set came: its order changes from one
        // context to the next, so a sync could store the same group under
        // another order of names. The row shows the stored title until its
        // participants load, and the stored title is part of the participant
        // rollup cache's token, so a reordered title was also a cache miss for
        // that row. The loader walks the same order, so the stored title and
        // the loaded one agree.
        let titleCandidates: [(person: Person, normalizedEmail: String)] = ConversationParticipantExtractor
            .displayOrderedParticipants(participants)
            .compactMap { entry in
                guard let person = entry.participant.person else { return nil }
                if EmailNormalizer.isHideMyEmailDisplayName(person.displayName) {
                    Log.diagnostic(
                        .conversationRollups,
                        "Excluding Hide My Email relay participant: \(person.email)",
                        category: .conversation
                    )
                    return nil
                }
                return (person: person, normalizedEmail: entry.normalizedEmail)
            }

        // Every address of the user's. `normalizedMyEmail` is added as it is,
        // empty or not: with no signed-in address, a row with no usable
        // address is still left out, as it was when `myEmail` alone was
        // compared.
        let allSelfAddresses = normalizedSelfAddresses.union([normalizedMyEmail])

        // The user's own addresses are left out of the title, as the loaded
        // title leaves them out (`storedSelfAddresses`). A conversation whose
        // only other participants are the user's aliases (mail sent to one's
        // own second address) keeps them: the loader has nobody to show for
        // it and draws this stored title, which would otherwise name nobody.
        let hasParticipantBeyondSelf = titleCandidates.contains { candidate in
            !candidate.normalizedEmail.isEmpty && !allSelfAddresses.contains(candidate.normalizedEmail)
        }
        let excludedSelfAddresses = hasParticipantBeyondSelf ? allSelfAddresses : [normalizedMyEmail]

        // Log all participants for debugging
        let allParticipantEmails = participants.compactMap { $0.person?.email }
        Log.diagnostic(
            .conversationRollups,
            "Conversation \(conversation.id): All participants: \(allParticipantEmails)",
            category: .conversation
        )
        Log.diagnostic(
            .conversationRollups,
            "My email: \(myEmail) (normalized: \(normalizedMyEmail))",
            category: .conversation
        )

        // Deduplicate participants by normalized email
        var seenEmails = Set<String>()
        var names: [String] = []
        var participantEmails: [String] = []
        var titled: [(person: Person, normalizedEmail: String)] = []

        for (person, normalizedEmail) in titleCandidates {
            let email = person.email

            // Exclude current user from display name
            if excludedSelfAddresses.contains(normalizedEmail) {
                Log.diagnostic(.conversationRollups, "Excluding self: \(email)", category: .conversation)
                continue
            }

            // Skip duplicates
            guard !seenEmails.contains(normalizedEmail) else { continue }
            seenEmails.insert(normalizedEmail)
            participantEmails.append(email)
            titled.append((person, normalizedEmail))
        }

        // The messages' senders, read once and only when the title needs them
        // (after the list conversation's early return below, which reads
        // none: architecture review 2026-11, sync-persist-path#2 stage 3).
        var readSenders: ConversationSenderSummary?
        func senderSummary() -> ConversationSenderSummary {
            if let readSenders { return readSenders }
            let summary = senders()
            readSenders = summary
            return summary
        }

        // A list conversation's title comes from its List-Id display phrase at
        // creation and has no relation to the (varying) participant rows. Keep
        // a stored title that isn't address-derived; otherwise fall through so
        // sender-derived names fill in and address-y placeholders self-correct.
        // An identifier-derived title is either the creation-time fallback for
        // a bare `List-Id: <id>` header or a provider phrase that embeds the same
        // opaque identifier. Upgrade it to the sender's From name once a single
        // distinct sender is known, so a newsletter shows its brand ("TBPN")
        // instead of provider metadata.
        if conversation.conversationType == .list {
            let sanitizedStoredTitle = PersonDisplayNameResolver.sanitizedConversationDisplayNameHint(
                conversation.displayName,
                participantEmails: participantEmails
            )
            let storedTitleIsIdentifierDerived = ParsedListId.isIdentifierDerivedDisplayTitle(
                conversation.displayName,
                listId: conversation.listId
            )

            if sanitizedStoredTitle != nil, !storedTitleIsIdentifierDerived {
                return
            }

            if storedTitleIsIdentifierDerived {
                if let senderName = singleSenderDisplayName(
                    for: conversation,
                    normalizedSelfAddresses: allSelfAddresses,
                    senders: senderSummary()
                ) {
                    if conversation.displayName != senderName {
                        conversation.displayName = senderName
                    }
                    return
                }

                // Multi-sender (or nameless) lists keep the stable List-Id
                // placeholder rather than a participant-derived join.
                return
            }
        }

        let headerDisplayNamesByEmail = senderSummary().headerDisplayNamesByEmail
        for (person, normalizedEmail) in titled {
            let email = person.email
            let resolvedName = PersonDisplayNameResolver.participantDisplayName(
                email: email,
                contactDisplayName: nil,
                headerDisplayName: headerDisplayNamesByEmail[normalizedEmail],
                storedDisplayName: person.displayName
            )
            guard resolvedName.isReal else {
                Log.diagnostic(
                    .conversationRollups,
                    "Including unresolved participant placeholder for: \(email)",
                    category: .conversation
                )
                continue
            }
            Log.diagnostic(.conversationRollups, "Including participant: \(resolvedName.name)", category: .conversation)
            names.append(resolvedName.name)
        }

        let finalDisplayName = PersonDisplayNameResolver.conversationDisplayName(
            realNames: names,
            totalParticipantCount: participantEmails.count,
            fallback: conversation.displayName,
            participantEmails: participantEmails
        )
        Log.diagnostic(
            .conversationRollups,
            "Final displayName: \(finalDisplayName), snippet: \(conversation.snippet ?? "nil")",
            category: .conversation
        )
        guard conversation.displayName != finalDisplayName else { return }
        conversation.displayName = finalDisplayName
    }

    /// Resolves the From display name of a list conversation's single distinct
    /// sender. Returns nil when the conversation has zero or multiple distinct
    /// non-self senders, or when no real name resolves for that sender. Self is
    /// every address of the user's (`storedSelfAddresses`): a post the user
    /// sent to the list from a send-as alias is the user's own, not a second
    /// sender that would keep the machine title.
    private func singleSenderDisplayName(
        for conversation: Conversation,
        normalizedSelfAddresses: Set<String>,
        senders: ConversationSenderSummary
    ) -> String? {
        let distinctSenderEmails = senders.senderEmails.subtracting(normalizedSelfAddresses)

        guard distinctSenderEmails.count == 1,
              let senderEmail = distinctSenderEmails.first else {
            return nil
        }

        let storedDisplayName = conversation.participants?
            .first { participant in
                guard let person = participant.person else { return false }
                return EmailNormalizer.normalize(person.email) == senderEmail
            }?
            .person?.displayName

        let resolved = PersonDisplayNameResolver.participantDisplayName(
            email: senderEmail,
            contactDisplayName: nil,
            headerDisplayName: senders.headerDisplayNamesByEmail[senderEmail],
            storedDisplayName: storedDisplayName
        )
        return resolved.isReal ? resolved.name : nil
    }
}
