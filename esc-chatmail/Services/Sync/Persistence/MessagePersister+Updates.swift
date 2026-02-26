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

        let existingMessage: Message?
        do {
            existingMessage = try context.fetch(request).first
        } catch {
            Log.error("Failed to fetch message for update", category: .coreData, error: error)
            return false
        }
        guard let existingMessage = existingMessage else {
            return false
        }

        let previousWasUnread = existingMessage.isUnread
        let previousHadInboxLabel = existingMessage.labels?.contains { $0.id == "INBOX" } ?? false
        let previousSnippet = existingMessage.snippet
        let previousBodyText = existingMessage.bodyText
        let previousBodyStorageURI = existingMessage.bodyStorageURI

        // Update existing message properties that might have changed
        existingMessage.isUnread = processedMessage.isUnread
        existingMessage.isNewsletter = processedMessage.isNewsletter
        existingMessage.snippet = processedMessage.snippet
        existingMessage.cleanedSnippet = processedMessage.cleanedSnippet

        if let plainText = processedMessage.plainTextBody, !plainText.isEmpty {
            existingMessage.bodyText = plainText
        }

        if let htmlBody = processedMessage.htmlBody,
           let fileURL = htmlContentHandler.saveHTML(htmlBody, for: processedMessage.id) {
            existingMessage.bodyStorageURI = fileURL.absoluteString
        }

        // Update labels - fetch all needed labels in a single batch query
        let messageLabelIds = Set(processedMessage.labelIds)
        let currentHasInboxLabel = messageLabelIds.contains("INBOX")
        existingMessage.labels = nil
        // Batch fetch labels (nonisolated function, safe to call directly)
        let labelCache = fetchLabelsByIds(messageLabelIds, in: context)
        for labelId in processedMessage.labelIds {
            if let label = labelCache[labelId] {
                existingMessage.addToLabels(label)
            }
        }

        // Merge attachments from server payload even when optimistic local attachments already exist.
        // This prevents missing inline CID images after sent-message reconciliation.
        var existingAttachmentIds = Set(existingMessage.attachmentsArray.compactMap(\.id))
        var existingContentIds = Set(existingMessage.attachmentsArray.compactMap { normalizedContentID($0.contentId) })

        for attachmentInfo in processedMessage.attachmentInfo {
            if existingAttachmentIds.contains(attachmentInfo.id) {
                continue
            }

            if let normalizedIncomingCID = normalizedContentID(attachmentInfo.contentId),
               existingContentIds.contains(normalizedIncomingCID) {
                continue
            }

            createAttachment(attachmentInfo, for: existingMessage, in: context)

            existingAttachmentIds.insert(attachmentInfo.id)
            if let normalizedIncomingCID = normalizedContentID(attachmentInfo.contentId) {
                existingContentIds.insert(normalizedIncomingCID)
            }
        }

        // Track the conversation as modified for rollup updates
        if let conversation = existingMessage.conversation {
            applyFastConversationListUpdateForExistingMessage(
                existingMessage,
                in: conversation,
                previousHadInboxLabel: previousHadInboxLabel,
                previousWasUnread: previousWasUnread,
                currentHasInboxLabel: currentHasInboxLabel,
                currentIsUnread: processedMessage.isUnread
            )
            await trackModifiedConversation(conversation)
        }

        let bodyStorageURIChanged = existingMessage.bodyStorageURI != previousBodyStorageURI
        let bodyTextChanged = existingMessage.bodyText != previousBodyText
        let snippetChanged = existingMessage.snippet != previousSnippet
        if bodyStorageURIChanged || bodyTextChanged || snippetChanged {
            await ProcessedTextCache.shared.invalidate(messageId: processedMessage.id)
            HTMLContentLoader.shared.invalidate(messageId: processedMessage.id)
        }

        Log.debug("Updated existing message: \(processedMessage.id)", category: .sync)
        return true
    }

    private func normalizedContentID(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }

        var normalized = rawValue
            .trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))

        while normalized.hasPrefix("/") {
            normalized.removeFirst()
        }

        normalized = normalized.removingPercentEncoding ?? normalized
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return nil }
        return normalized.lowercased()
    }
}
