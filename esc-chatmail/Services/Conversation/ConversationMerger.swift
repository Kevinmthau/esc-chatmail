import Foundation
import CoreData

/// Handles merging duplicate conversations and deduplication.
/// Extracted from ConversationManager for focused responsibility.
struct ConversationMerger: Sendable {
    private let coreDataStack: CoreDataStack

    init(coreDataStack: CoreDataStack = .shared) {
        self.coreDataStack = coreDataStack
    }

    /// Forwards deletions to the given contexts, excluding the work context that
    /// produced them. The work context already knows about these deletions;
    /// merging them back into it re-enters a context that is mid-`perform` and
    /// corrupts it, so it is always filtered out.
    private func mergeDeletions(
        _ deletedObjectIDs: [NSManagedObjectID],
        into contexts: [NSManagedObjectContext],
        excluding workContext: NSManagedObjectContext
    ) {
        let mergeTargets = contexts.filter { $0 !== workContext }
        guard !deletedObjectIDs.isEmpty, !mergeTargets.isEmpty else { return }
        NSManagedObjectContext.mergeChanges(
            fromRemoteContextSave: [NSDeletedObjectsKey: deletedObjectIDs],
            into: mergeTargets
        )
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

            let pendingSendConversationIds: Set<UUID>
            let pendingActionsByConversationID: [UUID: [PendingAction]]
            do {
                pendingSendConversationIds = try self.pendingSendConversationIDs(in: context)
                pendingActionsByConversationID = try PendingAction.referencesByConversationID(
                    in: context
                )
            } catch {
                Log.error(
                    "Failed to fetch protected references before duplicate conversation merge",
                    category: .coreData,
                    error: error
                )
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

                // A pending send owns its anchor's membership and rollup until
                // reconciliation or rollback. Exclude pending rows from both
                // winner selection and loser mutation; ordinary duplicates can
                // still collapse around the untouched anchor.
                let mergeableGroup = group.filter {
                    !pendingSendConversationIds.contains($0.id)
                }
                guard mergeableGroup.count > 1,
                      let winner = self.selectWinner(from: mergeableGroup) else {
                    continue
                }
                let losers = mergeableGroup.filter { $0 != winner }

                for loser in losers {
                    for action in pendingActionsByConversationID[loser.id] ?? [] {
                        action.conversationId = winner.id
                    }
                    self.merge(from: loser, into: winner)
                    deletedObjectIDs.append(loser.objectID)
                    context.delete(loser)
                    mergedCount += 1
                }
            }

            if mergedCount > 0 {
                guard self.coreDataStack.saveIfNeeded(context: context) else {
                    context.rollback()
                    return
                }

                self.mergeDeletions(deletedObjectIDs, into: [self.coreDataStack.viewContext], excluding: context)

                let duration = CFAbsoluteTimeGetCurrent() - startTime
                Log.info("Merged \(mergedCount) duplicate conversations in \(String(format: "%.3f", duration))s", category: .conversation)
            }
        }
    }

    // MARK: - Duplicate Removal by ParticipantHash

    /// Merges duplicate ACTIVE conversations that have the same participantHash.
    /// Handles race conditions where multiple conversations were created for the same participants.
    /// Returns the object IDs of winners that absorbed at least one loser, or nil
    /// when the merge could not be completed and persisted.
    @discardableResult
    func mergeActiveConversationDuplicates(
        in context: NSManagedObjectContext
    ) async -> Set<NSManagedObjectID>? {
        let startTime = CFAbsoluteTimeGetCurrent()

        return await context.perform {
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
                return nil
            }

            // Group by participantHash
            var byHash: [String: [Conversation]] = [:]
            for conv in conversations {
                guard let hash = conv.participantHash, !hash.isEmpty else { continue }
                byHash[hash, default: []].append(conv)
            }

            // Conversations referenced by in-flight optimistic sends must not be
            // deleted as merge losers: their optimistic message can be unsaved on
            // the view context (invisible here), and deleting the row would
            // orphan it and dangle the send-reconciliation record.
            let pendingSendConversationIds: Set<UUID>
            let pendingActionsByConversationID: [UUID: [PendingAction]]
            do {
                pendingSendConversationIds = try self.pendingSendConversationIDs(in: context)
                pendingActionsByConversationID = try PendingAction.referencesByConversationID(
                    in: context
                )
            } catch {
                Log.error(
                    "Failed to fetch protected references before active conversation merge",
                    category: .coreData,
                    error: error
                )
                return nil
            }

            var mergedCount = 0
            var mergedWinnerIDs: Set<NSManagedObjectID> = []
            var deletedObjectIDs = [NSManagedObjectID]()

            // Process groups with duplicates
            for (hash, group) in byHash where group.count > 1 {
                Log.debug("Found \(group.count) duplicate active conversations for participantHash: \(hash.prefix(16))...", category: .conversation)

                let mergeableGroup = group.filter {
                    !pendingSendConversationIds.contains($0.id)
                }
                guard mergeableGroup.count > 1,
                      let winner = self.selectWinner(from: mergeableGroup) else {
                    continue
                }
                let losers = mergeableGroup.filter { $0 != winner }
                mergedWinnerIDs.insert(winner.objectID)

                for loser in losers {
                    for action in pendingActionsByConversationID[loser.id] ?? [] {
                        action.conversationId = winner.id
                    }
                    self.merge(from: loser, into: winner)
                    deletedObjectIDs.append(loser.objectID)
                    context.delete(loser)
                    mergedCount += 1
                }
            }

            if mergedCount > 0 {
                guard self.coreDataStack.saveIfNeeded(context: context) else {
                    context.rollback()
                    return nil
                }

                self.mergeDeletions(deletedObjectIDs, into: [self.coreDataStack.viewContext], excluding: context)

                let duration = CFAbsoluteTimeGetCurrent() - startTime
                Log.info("Merged \(mergedCount) duplicate active conversations in \(String(format: "%.3f", duration))s", category: .conversation)
            }
            return mergedWinnerIDs
        }
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
        let wasPinned = winner.pinned || loser.pinned
        let wasMuted = winner.muted || loser.muted
        let loserMessages = loser.messages ?? []

        // Reassign all messages from loser to winner
        for message in loserMessages {
            message.conversation = winner
        }

        ConversationRollupSnapshot.make(
            from: (winner.messages ?? []).union(loserMessages)
        ).apply(to: winner)

        // Preserve conversation-level user state.
        winner.pinned = wasPinned
        winner.muted = wasMuted
    }

    private func visibilityRank(for conversation: Conversation) -> Int {
        if conversation.archivedAt == nil && !conversation.hidden { return 3 }
        if conversation.archivedAt == nil { return 2 }
        if !conversation.hidden { return 1 }
        return 0
    }

    private func pendingSendConversationIDs(
        in context: NSManagedObjectContext
    ) throws -> Set<UUID> {
        Set(try context.fetch(OutboundSendMutationRecord.fetchRequest()).compactMap(\.conversationId))
    }
}
