import Foundation
import CoreData

/// Serializes conversation creation to prevent duplicate conversations.
///
/// Uses an actor to ensure only one conversation per participant hash can be
/// resolved at a time, regardless of which Core Data context is being used.
actor ConversationCreationSerializer {
    static let shared = ConversationCreationSerializer()

    /// Participant hashes currently being resolved.
    /// Later callers wait for the active creator instead of racing through their own fetch/create.
    private var activeParticipantHashes: Set<String> = []
    private var waitingContinuations: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Finds or creates a conversation, ensuring no duplicates are created.
    /// - Parameters:
    ///   - identity: The conversation identity containing participants and type
    ///   - initialLastMessageDate: Optional date to set as lastMessageDate when creating a new conversation (prevents UI flash)
    ///   - context: The Core Data context to use
    func findOrCreateConversationObjectID(
        for identity: ConversationIdentity,
        initialLastMessageDate: Date? = nil,
        reactivateArchivedIfNeeded: Bool = true,
        in context: NSManagedObjectContext
    ) async throws -> NSManagedObjectID {
        let participantHash = identity.participantHash

        await claimTurn(for: participantHash)
        defer { releaseTurn(for: participantHash) }

        // Use NSManagedObjectID (which is Sendable) to avoid capturing non-Sendable Conversation
        // Use Result type since context.perform can't throw
        let result: Result<NSManagedObjectID, Error> = await context.perform {
            let routingPolicy = ConversationRoutingPolicy()

            // Look for existing conversations with these participants. Active
            // conversations are always eligible; archived conversations are only
            // reused when the caller's message should reactivate them.
            // Use includesPendingChanges = false to query the persistent store directly,
            // bypassing any in-memory changes that might not reflect other contexts' saves
            let request = Conversation.fetchRequest()
            request.predicate = NSPredicate(format: "participantHash == %@", participantHash)
            request.fetchBatchSize = 10
            request.includesPendingChanges = false  // Query persistent store, not just in-memory

            let matchingConversations: [Conversation]
            do {
                matchingConversations = try context.fetch(request)
            } catch {
                Log.error("Failed to fetch existing conversation for participantHash", category: .coreData, error: error)
                matchingConversations = []
            }

            if let existing = routingPolicy.selectParticipantHashConversation(
                from: matchingConversations,
                reactivateArchivedIfNeeded: reactivateArchivedIfNeeded
            ) {
                routingPolicy.reactivateArchivedConversationIfNeeded(
                    existing,
                    shouldReactivate: reactivateArchivedIfNeeded
                )
                return .success(existing.objectID)
            }

            // Create new conversation
            let conversation: Conversation
            do {
                conversation = try ConversationFactory.create(for: identity, initialLastMessageDate: initialLastMessageDate, in: context)
            } catch {
                Log.error("Failed to create conversation: \(error)", category: .coreData)
                return .failure(error)
            }

            // Save immediately
            if context.hasChanges {
                do {
                    try context.save()
                } catch {
                    Log.error("Failed to save new conversation: \(error)", category: .coreData)
                    return .failure(error)
                }
            }

            return .success(conversation.objectID)
        }

        let resultObjectID = try result.get()
        return resultObjectID
    }

    private func claimTurn(for hash: String) async {
        if !activeParticipantHashes.contains(hash) {
            activeParticipantHashes.insert(hash)
            return
        }

        await withCheckedContinuation { continuation in
            waitingContinuations[hash, default: []].append(continuation)
        }
    }

    private func releaseTurn(for hash: String) {
        if var continuations = waitingContinuations[hash], !continuations.isEmpty {
            let next = continuations.removeFirst()
            if continuations.isEmpty {
                waitingContinuations.removeValue(forKey: hash)
            } else {
                waitingContinuations[hash] = continuations
            }
            next.resume()
        } else {
            activeParticipantHashes.remove(hash)
        }
    }
}
