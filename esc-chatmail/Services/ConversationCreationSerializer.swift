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

        // Check if we recently created this conversation (may not be visible in this context yet)
        let shouldRefresh = recentlyCreatedHashes.contains(participantHash)

        // Use NSManagedObjectID (which is Sendable) to avoid capturing non-Sendable Conversation
        var resultObjectID: NSManagedObjectID!

        context.performAndWait {
            if shouldRefresh {
                // Refresh to see recently saved changes from other contexts
                context.refreshAllObjects()
            }

            // Look for an ACTIVE conversation with these participants
            let request = Conversation.fetchRequest()
            request.predicate = NSPredicate(
                format: "participantHash == %@ AND archivedAt == nil",
                participantHash
            )
            request.fetchLimit = 1

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

        // Track this hash so other contexts know to refresh
        recentlyCreatedHashes.insert(participantHash)

        // Schedule cleanup after 30 seconds (capture only the hash, not self directly)
        let hashToRemove = participantHash
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            await self?.removeFromCache(hashToRemove)
        }

        // Fetch the conversation object from the ID
        // swiftlint:disable:next force_cast
        return context.object(with: resultObjectID) as! Conversation
    }

    private func removeFromCache(_ hash: String) {
        recentlyCreatedHashes.remove(hash)
    }
}
