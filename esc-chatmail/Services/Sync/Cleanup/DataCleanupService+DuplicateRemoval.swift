import Foundation
import CoreData

// MARK: - Duplicate Removal

extension DataCleanupService {

    // There is no duplicate-message pass. `Message.id` has had a uniqueness
    // constraint since the first model version, so the store cannot hold two
    // rows with one ID, and the pass that looked for them read every message's
    // ID on each maintenance run to find nothing (`docs/scalability-review.md`,
    // `six-hour-maintenance-inside-sync-run`).

    /// Removes duplicate conversations by delegating to ConversationManager.
    func removeDuplicateConversations(in context: NSManagedObjectContext) async {
        await conversationManager.removeDuplicateConversations(in: context)
    }

    /// Merges active conversation duplicates by delegating to ConversationManager.
    @discardableResult
    func mergeActiveConversationDuplicates(
        in context: NSManagedObjectContext
    ) async -> Set<NSManagedObjectID>? {
        await conversationManager.mergeActiveConversationDuplicates(in: context)
    }
}
