import Foundation
import CoreData

/// Handles merging duplicate conversations and deduplication.
/// Extracted from ConversationManager for focused responsibility.
struct ConversationMerger: Sendable {
    private let coreDataStack: CoreDataStack

    init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    // MARK: - Duplicate Removal by KeyHash

    /// Removes duplicate conversations by keyHash.
    func removeDuplicateConversations(in context: NSManagedObjectContext) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        await context.perform {
            // Step 1: Find duplicate keyHashes using a lightweight dictionary fetch
            let countRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Conversation")
            countRequest.resultType = .dictionaryResultType
            countRequest.propertiesToFetch = ["keyHash"]

            let results: [[String: Any]]
            do {
                guard let fetched = try context.fetch(countRequest) as? [[String: Any]] else { return }
                results = fetched
            } catch {
                Log.error("Failed to fetch conversation keyHashes for duplicate detection", category: .coreData, error: error)
                return
            }

            // Build a map of keyHash -> count
            var keyHashCounts = [String: Int]()
            for result in results {
                if let keyHash = result["keyHash"] as? String, !keyHash.isEmpty {
                    keyHashCounts[keyHash, default: 0] += 1
                }
            }

            // Get keyHashes that appear more than once
            let duplicateKeyHashes = keyHashCounts.filter { $0.value > 1 }.map { $0.key }

            guard !duplicateKeyHashes.isEmpty else {
                return
            }

            var mergedCount = 0
            var deletedObjectIDs = [NSManagedObjectID]()

            // Step 2: Process each duplicate group
            for keyHash in duplicateKeyHashes {
                let request = Conversation.fetchRequest()
                request.predicate = NSPredicate(format: "keyHash == %@", keyHash)
                request.returnsObjectsAsFaults = false

                let group: [Conversation]
                do {
                    group = try context.fetch(request)
                    guard group.count > 1 else { continue }
                } catch {
                    Log.warning("Failed to fetch duplicate group for keyHash: \(keyHash.prefix(16))...", category: .coreData)
                    continue
                }

                guard let winner = self.selectWinner(from: group) else {
                    continue
                }
                let losers = group.filter { $0 != winner }

                for loser in losers {
                    self.merge(from: loser, into: winner)
                    deletedObjectIDs.append(loser.objectID)
                    context.delete(loser)
                    mergedCount += 1
                }
            }

            if mergedCount > 0 {
                self.coreDataStack.saveIfNeeded(context: context)

                if !deletedObjectIDs.isEmpty {
                    let changes = [NSDeletedObjectsKey: deletedObjectIDs]
                    NSManagedObjectContext.mergeChanges(
                        fromRemoteContextSave: changes,
                        into: [self.coreDataStack.viewContext]
                    )
                }

                let duration = CFAbsoluteTimeGetCurrent() - startTime
                Log.info("Merged \(mergedCount) duplicate conversations in \(String(format: "%.3f", duration))s", category: .conversation)
            }
        }
    }

    // MARK: - Duplicate Removal by ParticipantHash

    /// Merges duplicate ACTIVE conversations that have the same participantHash.
    /// Handles race conditions where multiple conversations were created for the same participants.
    func mergeActiveConversationDuplicates(in context: NSManagedObjectContext) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        await context.perform {
            // Find active conversations (archivedAt == nil) grouped by participantHash
            let request = Conversation.fetchRequest()
            request.predicate = NSPredicate(format: "archivedAt == nil")
            request.returnsObjectsAsFaults = false
            request.fetchBatchSize = 50

            let conversations: [Conversation]
            do {
                conversations = try context.fetch(request)
            } catch {
                Log.error("Failed to fetch active conversations for duplicate merge", category: .coreData, error: error)
                return
            }

            // Group by participantHash
            var byHash: [String: [Conversation]] = [:]
            for conv in conversations {
                guard let hash = conv.participantHash, !hash.isEmpty else { continue }
                byHash[hash, default: []].append(conv)
            }

            var mergedCount = 0
            var deletedObjectIDs = [NSManagedObjectID]()

            // Process groups with duplicates
            for (hash, group) in byHash where group.count > 1 {
                Log.debug("Found \(group.count) duplicate active conversations for participantHash: \(hash.prefix(16))...", category: .conversation)

                guard let winner = self.selectWinner(from: group) else {
                    continue
                }
                let losers = group.filter { $0 != winner }

                for loser in losers {
                    self.merge(from: loser, into: winner)
                    deletedObjectIDs.append(loser.objectID)
                    context.delete(loser)
                    mergedCount += 1
                }
            }

            if mergedCount > 0 {
                self.coreDataStack.saveIfNeeded(context: context)

                if !deletedObjectIDs.isEmpty {
                    let changes = [NSDeletedObjectsKey: deletedObjectIDs]
                    NSManagedObjectContext.mergeChanges(
                        fromRemoteContextSave: changes,
                        into: [self.coreDataStack.viewContext]
                    )
                }

                let duration = CFAbsoluteTimeGetCurrent() - startTime
                Log.info("Merged \(mergedCount) duplicate active conversations in \(String(format: "%.3f", duration))s", category: .conversation)
            }
        }
    }

    // MARK: - Thread-Based Merge (Gmail)

    /// Merges conversations when messages from the same Gmail thread (`gmThreadId`) have been split
    /// across multiple Conversation rows.
    ///
    /// This can happen when participant-based identity differs between messages in the same thread
    /// (common when `Reply-To` uses a different address than `From`).
    ///
    /// Forwarded-message splits are preserved: conversations containing explicit forwarding markers
    /// (subject prefixes or body quote markers) are intentionally kept separate from thread-wide merges.
    func mergeConversationsByGmThreadId(
        in context: NSManagedObjectContext,
        mergeChangesInto contextsToMerge: [NSManagedObjectContext]
    ) async -> Int {
        let startTime = CFAbsoluteTimeGetCurrent()

        return await context.perform {
            let request = Message.fetchRequest()
            request.predicate = NSPredicate(format: "gmThreadId != '' AND conversation != nil")
            request.fetchBatchSize = 500
            request.returnsObjectsAsFaults = true
            request.relationshipKeyPathsForPrefetching = ["conversation"]

            let messages: [Message]
            do {
                messages = try context.fetch(request)
            } catch {
                Log.error("Failed to fetch messages for gmThreadId conversation merge", category: .coreData, error: error)
                return 0
            }

            // Build a map of gmThreadId -> distinct conversation objectIDs.
            var threadToConversationIDs: [String: Set<NSManagedObjectID>] = [:]
            var threadToForwardedConversationIDs: [String: Set<NSManagedObjectID>] = [:]
            threadToConversationIDs.reserveCapacity(256)
            threadToForwardedConversationIDs.reserveCapacity(64)

            for message in messages {
                let threadId = message.gmThreadId
                guard !threadId.isEmpty, let conversation = message.conversation else { continue }
                threadToConversationIDs[threadId, default: []].insert(conversation.objectID)

                if ForwardingHeuristics.indicatesForwarding(
                    subject: message.subject,
                    contentCandidates: [message.bodyText, message.cleanedSnippet, message.snippet]
                ) {
                    threadToForwardedConversationIDs[threadId, default: []].insert(conversation.objectID)
                }
            }

            let duplicateThreads = threadToConversationIDs.filter { $0.value.count > 1 }
            guard !duplicateThreads.isEmpty else {
                return 0
            }

            var mergedCount = 0
            var deletedObjectIDs: [NSManagedObjectID] = []

            for (threadId, conversationIDs) in duplicateThreads {
                let forwardedConversationIDs = threadToForwardedConversationIDs[threadId] ?? []
                let mergeableConversationIDs = conversationIDs.subtracting(forwardedConversationIDs)

                if !forwardedConversationIDs.isEmpty && mergeableConversationIDs.count <= 1 {
                    Log.debug("Skipping gmThreadId merge for \(threadId.prefix(16))... to preserve forwarded conversation split", category: .conversation)
                    continue
                }

                let conversations: [Conversation] = mergeableConversationIDs.compactMap { objectID in
                    context.object(with: objectID) as? Conversation
                }
                guard conversations.count > 1 else { continue }

                guard let winner = self.selectWinner(from: conversations) else { continue }
                let losers = conversations.filter { $0 != winner }

                Log.debug("Merging \(losers.count) conversation(s) for gmThreadId: \(threadId.prefix(16))...", category: .conversation)

                for loser in losers {
                    self.merge(from: loser, into: winner)
                    deletedObjectIDs.append(loser.objectID)
                    context.delete(loser)
                    mergedCount += 1
                }
            }

            if mergedCount > 0 {
                self.coreDataStack.saveIfNeeded(context: context)

                if !deletedObjectIDs.isEmpty, !contextsToMerge.isEmpty {
                    let changes = [NSDeletedObjectsKey: deletedObjectIDs]
                    NSManagedObjectContext.mergeChanges(
                        fromRemoteContextSave: changes,
                        into: contextsToMerge
                    )
                }

                let duration = CFAbsoluteTimeGetCurrent() - startTime
                Log.info("Merged \(mergedCount) conversation(s) by gmThreadId in \(String(format: "%.3f", duration))s", category: .conversation)
            }

            return mergedCount
        }
    }

    /// Convenience wrapper that merges changes into the app's `viewContext`.
    @discardableResult
    func mergeConversationsByGmThreadId(in context: NSManagedObjectContext) async -> Int {
        await mergeConversationsByGmThreadId(in: context, mergeChangesInto: [coreDataStack.viewContext])
    }

    // MARK: - Winner Selection

    /// Selects the winner conversation from a group of duplicates.
    /// Winner prefers visible conversations, then the one with most messages, or if equal, the most recent.
    /// Returns nil if the group is empty (logs error instead of crashing).
    func selectWinner(from group: [Conversation]) -> Conversation? {
        guard let first = group.first else {
            Log.error("selectWinner called with empty group - this indicates a logic error in the caller", category: .conversation)
            return nil
        }

        let winner = group.max { (a, b) in
            let aVisibilityRank = visibilityRank(for: a)
            let bVisibilityRank = visibilityRank(for: b)
            if aVisibilityRank != bVisibilityRank { return aVisibilityRank < bVisibilityRank }

            let aCount = a.messages?.count ?? 0
            let bCount = b.messages?.count ?? 0
            if aCount != bCount { return aCount < bCount }
            let aDate = a.lastMessageDate ?? .distantPast
            let bDate = b.lastMessageDate ?? .distantPast
            return aDate < bDate
        }
        return winner ?? first
    }

    // MARK: - Merge Logic

    /// Merges messages and data from loser into winner.
    func merge(from loser: Conversation, into winner: Conversation) {
        let originalWinnerLastMessageDate = winner.lastMessageDate ?? .distantPast
        let loserLastMessageDate = loser.lastMessageDate ?? .distantPast

        // Reassign all messages from loser to winner
        if let messages = loser.messages {
            for message in messages {
                message.conversation = winner
            }
        }

        // Merge rollup data
        winner.lastMessageDate = max(originalWinnerLastMessageDate, loserLastMessageDate)

        if winner.snippet == nil ||
           loserLastMessageDate > originalWinnerLastMessageDate {
            winner.snippet = loser.snippet
        }

        winner.hasInbox = winner.hasInbox || loser.hasInbox
        winner.inboxUnreadCount += loser.inboxUnreadCount

        if let loserLatestInboxDate = loser.latestInboxDate {
            let winnerLatestInboxDate = winner.latestInboxDate ?? .distantPast
            winner.latestInboxDate = max(winnerLatestInboxDate, loserLatestInboxDate)
        }

        if winner.archivedAt == nil || loser.archivedAt == nil {
            winner.archivedAt = nil
        }
        winner.hidden = winner.hidden && loser.hidden

        // Preserve pinned status
        winner.pinned = winner.pinned || loser.pinned
    }

    private func visibilityRank(for conversation: Conversation) -> Int {
        if conversation.archivedAt == nil && !conversation.hidden { return 3 }
        if conversation.archivedAt == nil { return 2 }
        if !conversation.hidden { return 1 }
        return 0
    }
}
