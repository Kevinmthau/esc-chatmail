import Foundation
import CoreData

// MARK: - Message Updates

extension MessagePersister {

    /// Updates an existing message if it exists.
    /// - Returns: true if an existing message was found and updated
    func updateExistingMessage(
        _ processedMessage: ProcessedMessage,
        labelIds: Set<String>?,
        in context: NSManagedObjectContext
    ) async -> Bool {
        let request = Message.fetchRequest()
        request.predicate = MessagePredicates.id(processedMessage.id)

        guard let existingMessage = try? context.fetch(request).first else {
            return false
        }

        // Update existing message properties that might have changed
        existingMessage.isUnread = processedMessage.isUnread
        existingMessage.snippet = processedMessage.snippet
        existingMessage.cleanedSnippet = processedMessage.cleanedSnippet

        // Update labels - fetch all needed labels in a single batch query
        let messageLabelIds = Set(processedMessage.labelIds)
        existingMessage.labels = nil
        // Batch fetch labels (nonisolated function, safe to call directly)
        let labelCache = fetchLabelsByIds(messageLabelIds, in: context)
        for labelId in processedMessage.labelIds {
            if let label = labelCache[labelId] {
                existingMessage.addToLabels(label)
            }
        }

        // Only add attachments if the message doesn't already have them
        let existingAttachments = existingMessage.typedAttachments
        if existingAttachments.isEmpty {
            for attachmentInfo in processedMessage.attachmentInfo {
                createAttachment(attachmentInfo, for: existingMessage, in: context)
            }
        }

        // Track the conversation as modified for rollup updates
        if let conversation = existingMessage.conversation {
            trackModifiedConversation(conversation)
        }

        Log.debug("Updated existing message: \(processedMessage.id)", category: .sync)
        return true
    }
}
