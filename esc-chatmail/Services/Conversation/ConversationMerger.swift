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

                let winner = self.selectWinner(from: group)
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

                let winner = self.selectWinner(from: group)
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

    // MARK: - Winner Selection

    /// Selects the winner conversation from a group of duplicates.
    /// Winner is the one with most messages, or if equal, the most recent.
    func selectWinner(from group: [Conversation]) -> Conversation {
        return group.max { (a, b) in
            let aCount = a.messages?.count ?? 0
            let bCount = b.messages?.count ?? 0
            if aCount != bCount { return aCount < bCount }
            let aDate = a.lastMessageDate ?? .distantPast
            let bDate = b.lastMessageDate ?? .distantPast
            return aDate < bDate
        }!
    }

    // MARK: - Merge Logic

    /// Merges messages and data from loser into winner.
    func merge(from loser: Conversation, into winner: Conversation) {
        // Reassign all messages from loser to winner
        if let messages = loser.messages {
            for message in messages {
                message.conversation = winner
            }
        }

        // Merge rollup data
        winner.lastMessageDate = max(winner.lastMessageDate ?? .distantPast,
                                    loser.lastMessageDate ?? .distantPast)

        if winner.snippet == nil ||
           (loser.lastMessageDate ?? .distantPast) > (winner.lastMessageDate ?? .distantPast) {
            winner.snippet = loser.snippet
        }

        winner.hasInbox = winner.hasInbox || loser.hasInbox
        winner.inboxUnreadCount += loser.inboxUnreadCount

        if let loserLatestInboxDate = loser.latestInboxDate {
            let winnerLatestInboxDate = winner.latestInboxDate ?? .distantPast
            winner.latestInboxDate = max(winnerLatestInboxDate, loserLatestInboxDate)
        }

        // Preserve pinned status
        winner.pinned = winner.pinned || loser.pinned
    }
}
