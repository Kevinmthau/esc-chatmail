import Foundation
import CoreData

// MARK: - Cleanup Operations

extension DatabaseMaintenanceService {

    func performCleanup() async -> Bool {
        let context = coreDataStack.newBackgroundContext()

        return await context.perform {
            do {
                // Cleanup old messages (older than 90 days)
                let oldMessageDate = Date().addingTimeInterval(-90 * 24 * 60 * 60)
                let oldMessageRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Message")
                oldMessageRequest.predicate = MessagePredicates.olderThan(oldMessageDate)

                let deleteOldMessages = NSBatchDeleteRequest(fetchRequest: oldMessageRequest)
                deleteOldMessages.resultType = .resultTypeCount

                let oldMessageResult = try context.execute(deleteOldMessages) as? NSBatchDeleteResult
                Log.debug("Deleted \(oldMessageResult?.result ?? 0) old messages", category: .coreData)

                // Cleanup orphaned attachments
                let orphanedAttachmentRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Attachment")
                orphanedAttachmentRequest.predicate = AttachmentPredicates.orphaned

                let deleteOrphaned = NSBatchDeleteRequest(fetchRequest: orphanedAttachmentRequest)
                deleteOrphaned.resultType = .resultTypeCount

                let orphanedResult = try context.execute(deleteOrphaned) as? NSBatchDeleteResult
                Log.debug("Deleted \(orphanedResult?.result ?? 0) orphaned attachments", category: .coreData)

                // Cleanup empty conversations
                let emptyConversationRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "Conversation")
                emptyConversationRequest.predicate = ConversationPredicates.emptyMessages

                let deleteEmpty = NSBatchDeleteRequest(fetchRequest: emptyConversationRequest)
                deleteEmpty.resultType = .resultTypeCount

                let emptyResult = try context.execute(deleteEmpty) as? NSBatchDeleteResult
                Log.debug("Deleted \(emptyResult?.result ?? 0) empty conversations", category: .coreData)

                // Save changes
                try self.coreDataStack.save(context: context)
                return true
            } catch {
                Log.error("Database cleanup failed", category: .coreData, error: error)
                return false
            }
        }
    }
}
