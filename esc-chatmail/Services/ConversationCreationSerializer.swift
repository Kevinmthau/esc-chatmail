import Foundation
import CoreData

/// Serializes conversation creation to prevent duplicate conversations.
///
/// Uses a global lock to ensure only one conversation can be created at a time,
/// regardless of which Core Data context is being used.
final class ConversationCreationSerializer: @unchecked Sendable {
    static let shared = ConversationCreationSerializer()

    /// Global lock for conversation creation - ensures atomic find-or-create
    private let lock = NSLock()

    /// Recently created conversation hashes - prevents duplicates across contexts
    /// before Core Data has a chance to propagate changes
    private var recentlyCreatedHashes: Set<String> = []

    /// Finds or creates a conversation, ensuring no duplicates are created.
    func findOrCreateConversation(
        for identity: ConversationIdentity,
        in context: NSManagedObjectContext
    ) async -> Conversation {
        let participantHash = identity.participantHash

        // Use a global lock to serialize ALL conversation creation
        // performAndWait is synchronous, so holding the lock is safe
        lock.lock()

        // Check if we recently created this conversation (may not be visible in this context yet)
        let shouldRefresh = recentlyCreatedHashes.contains(participantHash)

        var result: Conversation!

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
                result = existing
                return
            }

            // Create new conversation
            let conversation = ConversationFactory.create(for: identity, in: context)

            // Save immediately
            if context.hasChanges {
                do {
                    try context.save()
                    // Track this hash so other contexts know to refresh
                    self.recentlyCreatedHashes.insert(participantHash)
                    // Clean up after 30 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                        self?.removeFromCache(participantHash)
                    }
                } catch {
                    print("Failed to save new conversation: \(error)")
                }
            }

            result = conversation
        }

        lock.unlock()
        return result
    }

    private func removeFromCache(_ hash: String) {
        lock.lock()
        recentlyCreatedHashes.remove(hash)
        lock.unlock()
    }
}
