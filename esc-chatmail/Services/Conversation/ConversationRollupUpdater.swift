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

    init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    // MARK: - Single Conversation Rollup

    /// Updates rollup data for a conversation. Must be called from within the conversation's context queue.
    /// - Parameters:
    ///   - conversation: The conversation to update
    ///   - myEmail: The current user's email (must be captured before entering context.perform block)
    func updateRollups(for conversation: Conversation, myEmail: String) {
        guard conversation.managedObjectContext != nil else { return }
        let messages = conversation.messages ?? []
        let snapshot = ConversationRollupSnapshot.make(from: messages)
        logRollupSnapshot(snapshot, for: conversation, totalCount: messages.count)
        snapshot.apply(to: conversation)

        updateDisplayNameOnly(for: conversation, myEmail: myEmail)
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

            for conversation in conversations {
                self.updateRollups(for: conversation, myEmail: myEmail)
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
            // Use batch fetch with prefetching instead of individual existingObject calls
            // This avoids N+1 queries when accessing messages/labels/participants
            let request = Conversation.fetchRequest()
            request.predicate = NSPredicate(format: "SELF IN %@", conversationIDs)
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
                Log.error("Failed to batch fetch conversations for rollup update", category: .conversation, error: error)
                return false
            }

            for conversation in conversations {
                self.updateRollups(for: conversation, myEmail: myEmail)
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

            for conversation in conversations {
                self.updateRollups(for: conversation, myEmail: myEmail)
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

            for conversation in conversations {
                self.updateDisplayNameOnly(for: conversation, myEmail: myEmail)
            }
        }
    }

    /// Refreshes stored display names for selected conversations without recomputing rollups.
    @MainActor
    func updateDisplayNamesForConversations(
        conversationIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext,
        myEmail: String
    ) async {
        guard !conversationIDs.isEmpty else { return }

        await context.perform {
            let request = Conversation.fetchRequest()
            request.predicate = NSPredicate(format: "SELF IN %@", conversationIDs)
            request.relationshipKeyPathsForPrefetching = [
                "messages",
                "participants",
                "participants.person"
            ]

            let conversations: [Conversation]
            do {
                conversations = try context.fetch(request)
            } catch {
                Log.error("Failed to fetch conversations for display-name update", category: .conversation, error: error)
                return
            }

            for conversation in conversations {
                self.updateDisplayNameOnly(for: conversation, myEmail: myEmail)
            }
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
            for conversation in candidates {
                let titleBefore = conversation.displayName
                self.updateDisplayNameOnly(for: conversation, myEmail: myEmail)
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
        guard let participants = conversation.participants else { return }

        let normalizedMyEmail = EmailNormalizer.normalize(myEmail)

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
        let headerDisplayNamesByEmail = headerDisplayNamesByEmail(from: conversation)

        for participant in participants {
            guard let person = participant.person else { continue }
            if EmailNormalizer.isHideMyEmailDisplayName(person.displayName) {
                Log.diagnostic(
                    .conversationRollups,
                    "Excluding Hide My Email relay participant: \(person.email)",
                    category: .conversation
                )
                continue
            }
            let email = person.email
            let normalizedEmail = EmailNormalizer.normalize(email)

            // Exclude current user from display name
            if normalizedEmail == normalizedMyEmail {
                Log.diagnostic(.conversationRollups, "Excluding self: \(email)", category: .conversation)
                continue
            }

            // Skip duplicates
            guard !seenEmails.contains(normalizedEmail) else { continue }
            seenEmails.insert(normalizedEmail)
            participantEmails.append(email)

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
                    normalizedMyEmail: normalizedMyEmail,
                    headerDisplayNamesByEmail: headerDisplayNamesByEmail
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
    /// non-self senders, or when no real name resolves for that sender.
    private func singleSenderDisplayName(
        for conversation: Conversation,
        normalizedMyEmail: String,
        headerDisplayNamesByEmail: [String: String]
    ) -> String? {
        guard let messages = conversation.messages else { return nil }

        var distinctSenderEmails = Set<String>()
        for message in messages {
            guard let senderEmail = message.senderEmail else { continue }
            let normalizedEmail = EmailNormalizer.normalize(senderEmail)
            guard !normalizedEmail.isEmpty,
                  normalizedEmail != normalizedMyEmail else { continue }
            distinctSenderEmails.insert(normalizedEmail)
        }

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
            headerDisplayName: headerDisplayNamesByEmail[senderEmail],
            storedDisplayName: storedDisplayName
        )
        return resolved.isReal ? resolved.name : nil
    }

    private func headerDisplayNamesByEmail(from conversation: Conversation) -> [String: String] {
        guard let messages = conversation.messages else { return [:] }

        // Newest-first so the most recent From header wins; an older, fuller
        // variant of the same name may still upgrade it (see
        // EmailNormalizer.mergeNewestFirstHeaderDisplayName). One unordered
        // pass records each distinct sanitized name's newest occurrence;
        // ranking those candidates reproduces a full newest-first scan
        // without sorting a large thread's entire message set.
        var candidatesByEmail: [String: [String: (date: Date, id: String)]] = [:]
        for message in messages {
            guard let senderEmail = message.senderEmail else { continue }
            let normalizedEmail = EmailNormalizer.normalize(senderEmail)
            guard !normalizedEmail.isEmpty,
                  let displayName = PersonDisplayNameResolver.sanitizedExplicitDisplayName(
                    message.senderName,
                    forEmail: normalizedEmail
                  ) else {
                continue
            }

            let newest = candidatesByEmail[normalizedEmail]?[displayName]
            if newest == nil
                || message.internalDate > newest!.date
                || (message.internalDate == newest!.date && message.id > newest!.id) {
                candidatesByEmail[normalizedEmail, default: [:]][displayName] = (message.internalDate, message.id)
            }
        }

        var displayNames: [String: String] = [:]
        for (email, candidates) in candidatesByEmail {
            let ranked = candidates.map { name, newest in
                EmailNormalizer.HeaderDisplayNameCandidate(
                    displayName: name,
                    newestInternalDate: newest.date,
                    newestMessageID: newest.id
                )
            }
            if let winner = EmailNormalizer.resolveNewestFirstHeaderDisplayName(from: ranked, forEmail: email) {
                displayNames[email] = winner
            }
        }

        return displayNames
    }
}
