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
    ///   - initialSnippet: Optional row preview seeded at creation, since this save publishes the row before its first message persists
    ///   - initialInboxSeed: Optional inbox indicators seeded at creation, so the published row carries its unread dot alongside the preview
    ///   - context: The Core Data context to use
    func findOrCreateConversationObjectID(
        for identity: ConversationIdentity,
        initialLastMessageDate: Date? = nil,
        initialSnippet: String? = nil,
        initialInboxSeed: ConversationInboxSeed? = nil,
        reactivateArchivedIfNeeded: Bool = true,
        in context: NSManagedObjectContext
    ) async throws -> NSManagedObjectID {
        let participantHash = identity.participantHash

        await claimTurn(for: participantHash)
        defer { releaseTurn(for: participantHash) }

        // Phase 1: look for existing conversations with these participants on
        // the caller's context. Active conversations are always eligible;
        // archived conversations are only reused when the caller's message
        // should reactivate them. includesPendingChanges = false queries the
        // persistent store directly, bypassing in-memory changes that might
        // not reflect other contexts' saves. A failed lookup throws — creating
        // anyway could duplicate a conversation that exists but could not be
        // read.
        let existingObjectID: NSManagedObjectID? = try await context.perform {
            let routingPolicy = ConversationRoutingPolicy()
            let request = Conversation.fetchRequest()
            request.predicate = NSPredicate(format: "participantHash == %@", participantHash)
            request.fetchBatchSize = 10
            request.includesPendingChanges = false  // Query persistent store, not just in-memory

            let matchingConversations: [Conversation]
            do {
                matchingConversations = try context.fetch(request)
            } catch {
                Log.error("Failed to fetch existing conversation for participantHash", category: .coreData, error: error)
                throw error
            }

            guard let existing = routingPolicy.selectParticipantHashConversation(
                from: matchingConversations,
                reactivateArchivedIfNeeded: reactivateArchivedIfNeeded
            ) else {
                return nil
            }
            routingPolicy.reactivateArchivedConversationIfNeeded(
                existing,
                shouldReactivate: reactivateArchivedIfNeeded
            )
            return existing.objectID
        }
        if let existingObjectID {
            return existingObjectID
        }

        // Phase 2: create and commit the conversation SHELL in a dedicated
        // sibling context so the save publishes only the new row. The shell
        // must be store-visible immediately (cross-context and intra-batch
        // dedup both use includesPendingChanges = false fetches, and the row
        // publishes to the UI before its first message persists), but saving
        // the caller's context here would commit half-processed batch state —
        // and bypass the orchestrator's allowsIntermediateContextSaves guard.
        // The save also yields the permanent objectID callers rely on.
        guard let coordinator = context.persistentStoreCoordinator else {
            throw CoreDataError.persistentFailure(
                NSError(
                    domain: "ConversationCreationSerializer",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Caller context has no persistent store coordinator"]
                )
            )
        }
        let shellContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        shellContext.persistentStoreCoordinator = coordinator
        shellContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        let shellObjectID: NSManagedObjectID = try await shellContext.perform {
            let shell: Conversation
            do {
                shell = try ConversationFactory.createShell(
                    for: identity,
                    initialLastMessageDate: initialLastMessageDate,
                    initialSnippet: initialSnippet,
                    initialInboxSeed: initialInboxSeed,
                    in: shellContext
                )
            } catch {
                Log.error("Failed to create conversation: \(error)", category: .coreData)
                throw error
            }
            do {
                try shellContext.save()
            } catch {
                Log.error("Failed to save new conversation: \(error)", category: .coreData)
                throw error
            }
            return shell.objectID
        }

        // Phase 3: attach participants in the caller's context, where Person
        // resolution hits the batch-prefetched factory cache (a sibling
        // context would mint duplicate Person rows — Person.email has no
        // uniqueness constraint). Participants ride the caller's next save.
        // If attachment fails, the durable shell is participant-less; the
        // messageless-conversation grace-period repair covers that window.
        try await context.perform {
            guard let conversation = try context.existingObject(with: shellObjectID) as? Conversation else {
                throw CoreDataError.entityCreationFailed("Conversation")
            }
            try ConversationFactory.attachParticipants(for: identity, to: conversation, in: context)
        }

        return shellObjectID
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
