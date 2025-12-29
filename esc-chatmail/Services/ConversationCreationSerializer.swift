import Foundation
import CoreData

/// Serializes conversation creation to prevent duplicate conversations.
///
/// Uses an actor to ensure only one conversation can be created at a time,
/// regardless of which Core Data context is being used.
actor ConversationCreationSerializer {
    static let shared = ConversationCreationSerializer()

    /// Recently created conversation hashes - prevents duplicates across contexts
    /// before Core Data has a chance to propagate changes
    private var recentlyCreatedHashes: Set<String> = []

    /// Finds or creates a conversation, ensuring no duplicates are created.
    func findOrCreateConversation(
        for identity: ConversationIdentity,
        in context: NSManagedObjectContext
    ) -> Conversation {
        let participantHash = identity.participantHash

        // Pre-register this hash to prevent concurrent creation attempts
        // This is the key fix: register BEFORE we start the Core Data transaction
        // The actor ensures only one call executes at a time, so if we see the hash
        // already registered, a previous call already created the conversation
        let isNewRegistration = !recentlyCreatedHashes.contains(participantHash)
        recentlyCreatedHashes.insert(participantHash)

        // Use NSManagedObjectID (which is Sendable) to avoid capturing non-Sendable Conversation
        var resultObjectID: NSManagedObjectID!

        context.performAndWait {
            // Look for an ACTIVE conversation with these participants
            // Use includesPendingChanges = false to query the persistent store directly,
            // bypassing any in-memory changes that might not reflect other contexts' saves
            let request = Conversation.fetchRequest()
            request.predicate = NSPredicate(
                format: "participantHash == %@ AND archivedAt == nil",
                participantHash
            )
            request.fetchLimit = 1
            request.includesPendingChanges = false  // Query persistent store, not just in-memory

            if let existing = try? context.fetch(request).first {
                resultObjectID = existing.objectID
                return
            }

            // Create new conversation
            let conversation = ConversationFactory.create(for: identity, in: context)

            // Save immediately
            if context.hasChanges {
                do {
                    try context.save()
                } catch {
                    Log.error("Failed to save new conversation: \(error)", category: .coreData)
                }
            }

            resultObjectID = conversation.objectID
        }

        // Schedule cleanup after 30 seconds (only if we registered it)
        if isNewRegistration {
            let hashToRemove = participantHash
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                await self?.removeFromCache(hashToRemove)
            }
        }

        // Fetch the conversation object from the ID
        // swiftlint:disable:next force_cast
        return context.object(with: resultObjectID) as! Conversation
    }

    private func removeFromCache(_ hash: String) {
        recentlyCreatedHashes.remove(hash)
    }
}
