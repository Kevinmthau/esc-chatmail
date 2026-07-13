import Foundation
import CoreData

// MARK: - Message Creation

private struct MessageCreationResult {
    let participantEmails: [String]
    let modifiedConversationID: NSManagedObjectID
}

extension MessagePersister {

    /// Creates a new message in Core Data.
    func createNewMessage(
        _ processedMessage: ProcessedMessage,
        labelIds: Set<String>?,
        myAliases: Set<String>,
        modificationTransaction: ModificationTracker.Transaction? = nil,
        in context: NSManagedObjectContext
    ) async throws {
        let saveHTML = self.saveHTML
        let canonicalHTML = processedMessage.canonicalContent?.html ?? processedMessage.htmlBody
        let savedBodyStorageURI = canonicalHTML.flatMap {
            saveHTML($0, processedMessage.id)?.absoluteString
        }
        let conversationObjectID = try await conversationRouter.resolveConversationObjectID(
            for: processedMessage,
            myAliases: myAliases,
            in: context
        )

        let result = try await context.perform { () throws -> MessageCreationResult in
            guard let conversation = try context.existingObject(with: conversationObjectID) as? Conversation else {
                throw CoreDataError.persistentFailure(
                    NSError(
                        domain: "MessagePersister",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Resolved conversation was unavailable in the sync context"]
                    )
                )
            }

            guard let message = NSEntityDescription.insertNewObject(
                forEntityName: "Message",
                into: context
            ) as? Message else {
                throw CoreDataError.entityCreationFailed("Message")
            }
            message.id = processedMessage.id
            message.gmThreadId = processedMessage.gmThreadId
            message.snippet = processedMessage.snippet
            message.cleanedSnippet = processedMessage.cleanedSnippet
            message.chatPreviewText = processedMessage.chatPreviewText
            message.deliveredToAddress = processedMessage.headers.deliveredToAddress
            message.replyFromAddress = processedMessage.headers.replyFromAddress
            message.conversation = conversation
            message.internalDate = processedMessage.internalDate
            message.subject = processedMessage.headers.subject
            message.isFromMe = processedMessage.headers.isFromMe
            message.isUnread = processedMessage.isUnread
            message.isNewsletter = processedMessage.isNewsletter
            message.hasAttachments = processedMessage.hasAttachments

            message.setValue(processedMessage.headers.messageId, forKey: "messageId")
            message.setValue(processedMessage.headers.references.joined(separator: " "), forKey: "references")
            message.setValue(processedMessage.plainTextBody, forKey: "bodyText")

            if let from = processedMessage.headers.from {
                if let email = EmailNormalizer.extractEmail(from: from) {
                    message.setValue(email, forKey: "senderEmail")
                }
                if let displayName = EmailNormalizer.extractDisplayName(from: from) {
                    message.setValue(displayName, forKey: "senderName")
                }
            }

            let participantEmails = self.saveParticipants(
                for: processedMessage,
                message: message,
                in: context
            )

            let messageLabelIds = Set(processedMessage.labelIds)
            let hasInboxLabel = messageLabelIds.contains("INBOX")
            var addedLabelIds: [String] = []
            // An empty prefetched set means the label lookup failed, not that
            // the store has no labels; treating it as authoritative would strip
            // every label relationship and let the rollup recompute persist a
            // durable zero unread count.
            let availableLabelIds = labelIds.flatMap { $0.isEmpty ? nil : messageLabelIds.intersection($0) } ?? messageLabelIds
            let effectiveLabelCache = self.fetchLabelsByIds(availableLabelIds, in: context)
            for labelId in processedMessage.labelIds {
                if let label = effectiveLabelCache[labelId] {
                    message.addToLabels(label)
                    addedLabelIds.append(labelId)
                }
            }

            Log.debug(
                "New message \(Log.hashIdentifier(processedMessage.id)): labels=\(addedLabelIds), hasINBOX=\(hasInboxLabel), conversationId=\(Log.hashIdentifier(conversation.id.uuidString))",
                category: .sync
            )

            if let savedBodyStorageURI {
                message.bodyStorageURI = savedBodyStorageURI
            }

            for attachmentInfo in processedMessage.attachmentInfo {
                self.createAttachment(attachmentInfo, for: message, in: context)
            }

            self.applyFastConversationListUpdateForNewMessage(
                message,
                in: conversation,
                hasInboxLabel: hasInboxLabel
            )

            return MessageCreationResult(
                participantEmails: participantEmails,
                modifiedConversationID: conversation.objectID
            )
        }

        await scheduleInlineCIDPrefetchIfNeeded(for: processedMessage, in: context)

        if !result.participantEmails.isEmpty {
            for email in result.participantEmails {
                await PersonCache.shared.invalidateEntry(for: email)
            }

            let photoPrefetcher = self.photoPrefetcher
            let participantEmails = result.participantEmails
            Task.detached(priority: .background) {
                await photoPrefetcher(participantEmails)
            }
        }

        await ModificationTracker.shared.trackModifiedConversation(
            result.modifiedConversationID,
            in: modificationTransaction
        )
    }
}
