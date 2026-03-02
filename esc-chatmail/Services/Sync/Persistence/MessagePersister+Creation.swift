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
        let shouldReactivateConversation = processedMessage.labelIds.contains("INBOX")

        let isForwardedMessage = ForwardingHeuristics.indicatesForwarding(
            subject: processedMessage.headers.subject,
            contentCandidates: [
                processedMessage.plainTextBody,
                processedMessage.htmlBody,
                processedMessage.cleanedSnippet,
                processedMessage.snippet
            ]
        )

        // Prefer grouping by Gmail threadId to avoid splitting a single Gmail thread into
        // multiple chats when participant sets differ across messages (e.g. Reply-To aliases).
        // But if the message looks like a forwarded branch, use participant-based routing.
        let conversation: Conversation
        if !isForwardedMessage,
           let existingConversation = findExistingConversation(forGmThreadId: processedMessage.gmThreadId, in: context) {
            // Reactivate archived conversation when new messages arrive in the same thread.
            if shouldReactivateConversation, existingConversation.archivedAt != nil {
                existingConversation.archivedAt = nil
                existingConversation.hidden = false
            }
            conversation = existingConversation
        } else {
            // Fallback: participant-based identity (iMessage-style) when we haven't seen this thread yet.
            let identity = conversationManager.createConversationIdentity(
                from: processedMessage.headers,
                gmThreadId: processedMessage.gmThreadId,
                myAliases: myAliases
            )
            // Pass internalDate so new conversations appear at the correct position immediately
            // (prevents UI flash where conversation appears at bottom before moving to top)
            conversation = try await conversationManager.findOrCreateConversation(
                for: identity,
                initialLastMessageDate: processedMessage.internalDate,
                reactivateArchivedIfNeeded: shouldReactivateConversation,
                in: context
            )
        }

        // Create Core Data message entity
        guard let message = NSEntityDescription.insertNewObject(forEntityName: "Message", into: context) as? Message else {
            throw CoreDataError.entityCreationFailed("Message")
        }
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

        // Update list-critical fields immediately (unread dot + preview text).
        applyFastConversationListUpdateForNewMessage(
            message,
            in: conversation,
            hasInboxLabel: hasInboxLabel
        )

        // Track the conversation as modified for rollup updates
        await trackModifiedConversation(conversation)
    }
}
