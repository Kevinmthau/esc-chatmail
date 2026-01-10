import Foundation
import CoreData

// MARK: - Message Creation

extension MessagePersister {

    /// Creates a new message in Core Data.
    func createNewMessage(
        _ processedMessage: ProcessedMessage,
        labelIds: Set<String>?,
        myAliases: Set<String>,
        in context: NSManagedObjectContext
    ) async throws {
        // Create conversation identity using Gmail threadId as primary key
        // This ensures stable conversation grouping that matches Gmail's threading
        let identity = conversationManager.createConversationIdentity(
            from: processedMessage.headers,
            gmThreadId: processedMessage.gmThreadId,
            myAliases: myAliases
        )
        let conversation = try await conversationManager.findOrCreateConversation(for: identity, in: context)

        // Create Core Data message entity
        let message = NSEntityDescription.insertNewObject(forEntityName: "Message", into: context) as! Message
        message.id = processedMessage.id
        message.gmThreadId = processedMessage.gmThreadId
        message.snippet = processedMessage.snippet
        message.cleanedSnippet = processedMessage.cleanedSnippet
        message.conversation = conversation
        message.internalDate = processedMessage.internalDate
        message.subject = processedMessage.headers.subject
        message.isFromMe = processedMessage.headers.isFromMe
        message.isUnread = processedMessage.isUnread
        message.isNewsletter = processedMessage.isNewsletter
        message.hasAttachments = processedMessage.hasAttachments

        // Store message threading headers
        message.setValue(processedMessage.headers.messageId, forKey: "messageId")
        message.setValue(processedMessage.headers.references.joined(separator: " "), forKey: "references")

        // Store plain text body for quoting in replies
        message.setValue(processedMessage.plainTextBody, forKey: "bodyText")

        // Store sender information for reply attribution
        if let from = processedMessage.headers.from {
            if let email = EmailNormalizer.extractEmail(from: from) {
                message.setValue(email, forKey: "senderEmail")
            }
            if let displayName = EmailNormalizer.extractDisplayName(from: from) {
                message.setValue(displayName, forKey: "senderName")
            }
        }

        // Save participants
        let participantEmails = await saveParticipants(for: processedMessage, message: message, in: context)

        // Prefetch avatars for new participants in background (non-blocking)
        if !participantEmails.isEmpty {
            Task.detached(priority: .background) {
                await ProfilePhotoResolver.shared.prefetchPhotos(for: participantEmails)
            }
        }

        // Save labels - fetch all needed labels in a single batch query for efficiency
        let messageLabelIds = Set(processedMessage.labelIds)
        let hasInboxLabel = messageLabelIds.contains("INBOX")
        var addedLabelIds: [String] = []
        // Batch fetch labels (nonisolated function, safe to call directly)
        let labelCache = fetchLabelsByIds(messageLabelIds, in: context)
        for labelId in processedMessage.labelIds {
            if let label = labelCache[labelId] {
                message.addToLabels(label)
                addedLabelIds.append(labelId)
            }
        }
        Log.debug("New message \(processedMessage.id): labels=\(addedLabelIds), hasINBOX=\(hasInboxLabel), conversationId=\(conversation.id.uuidString)", category: .sync)

        // Save HTML content if present
        if let htmlBody = processedMessage.htmlBody {
            if let fileURL = htmlContentHandler.saveHTML(htmlBody, for: processedMessage.id) {
                message.bodyStorageURI = fileURL.absoluteString
            }
        }

        // Save attachment info
        for attachmentInfo in processedMessage.attachmentInfo {
            createAttachment(attachmentInfo, for: message, in: context)
        }

        // Update conversation's lastMessageDate to bump it to the top
        if conversation.lastMessageDate == nil || message.internalDate > conversation.lastMessageDate! {
            conversation.lastMessageDate = message.internalDate
            if message.isNewsletter, let subject = message.subject, !subject.isEmpty {
                conversation.snippet = subject
            } else {
                conversation.snippet = message.cleanedSnippet ?? message.snippet
            }
        }

        // Track the conversation as modified for rollup updates
        trackModifiedConversation(conversation)
    }
}
