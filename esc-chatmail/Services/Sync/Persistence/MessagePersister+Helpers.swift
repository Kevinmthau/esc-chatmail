import Foundation
import CoreData

// MARK: - Helper Methods

extension MessagePersister {

    /// Creates an attachment entity using AttachmentFactory.
    func createAttachment(
        _ info: AttachmentInfo,
        for message: Message,
        in context: NSManagedObjectContext
    ) {
        _ = AttachmentFactory.create(from: info, for: message, in: context)
    }

    /// Finds a label by ID.
    func findLabel(id: String, in context: NSManagedObjectContext) async -> Label? {
        let request = Label.fetchRequest()
        request.predicate = LabelPredicates.id(id)
        do {
            let label = try context.fetch(request).first
            if label == nil {
                // Log missing labels for debugging - this can happen if labels haven't been synced yet
                Log.debug("Label '\(id)' not found in local cache", category: .sync)
            }
            return label
        } catch {
            Log.error("Error fetching label '\(id)'", category: .sync, error: error)
            return nil
        }
    }

    /// Tracks a conversation as modified for rollup updates.
    /// Delegates to the shared ModificationTracker for consolidated tracking.
    func trackModifiedConversation(_ conversation: Conversation) async {
        await ModificationTracker.shared.trackModifiedConversation(conversation.objectID)
    }
}
