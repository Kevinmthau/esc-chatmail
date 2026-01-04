import Foundation
import CoreData

// MARK: - Archive Model Migration

extension DataCleanupService {

    /// Migrates existing conversations to the new archive model
    /// - Sets archivedAt for conversations that are hidden or have no inbox messages
    /// - Sets participantHash for conversations that don't have one
    func migrateConversationsToArchiveModel(in context: NSManagedObjectContext) async {
        let hasDoneMigration = UserDefaults.standard.bool(forKey: "hasDoneArchiveModelMigrationV1")
        guard !hasDoneMigration else { return }

        Log.info("Starting archive model migration...", category: .coreData)
        let startTime = CFAbsoluteTimeGetCurrent()

        await context.perform {
            let request = Conversation.fetchRequest()
            request.fetchBatchSize = 50

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

        UserDefaults.standard.set(true, forKey: "hasDoneArchiveModelMigrationV1")
    }

    /// Fixes conversations with incorrect participantHashes (e.g., ones that include the user's email)
    /// and merges them with the correct conversation.
    func fixAndMergeIncorrectParticipantHashes(in context: NSManagedObjectContext) async {
        let startTime = CFAbsoluteTimeGetCurrent()

        await context.perform { [self] in
            // Get user's aliases from Account
            let accountRequest = Account.fetchRequest()
            accountRequest.fetchLimit = 1
            guard let account = try? context.fetch(accountRequest).first else { return }

            let myAliases = Set(([account.email] + account.aliasesArray).map(normalizedEmail))
            guard !myAliases.isEmpty else { return }

            // Fetch all active conversations
            let request = Conversation.fetchRequest()
            request.predicate = ConversationPredicates.active
            request.returnsObjectsAsFaults = false

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

                let winner = conversationManager.selectWinnerConversation(from: group)
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
