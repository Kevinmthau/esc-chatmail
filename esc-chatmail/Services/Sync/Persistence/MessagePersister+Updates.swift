import Foundation
import CoreData

// MARK: - Message Updates

private struct MessageUpdateResult {
    let didUpdate: Bool
    let modifiedConversationID: NSManagedObjectID?
    let shouldInvalidateRenderedContent: Bool
}

extension MessagePersister {

    /// Updates an existing message if it exists.
    /// - Returns: true if an existing message was found and updated
    func updateExistingMessage(
        _ processedMessage: ProcessedMessage,
        labelIds: Set<String>?,
        in context: NSManagedObjectContext
    ) async -> Bool {
        let saveHTML = self.saveHTML

        let result: MessageUpdateResult = await context.perform {
            let request = Message.fetchRequest()
            request.predicate = MessagePredicates.id(processedMessage.id)

            let existingMessage: Message?
            do {
                existingMessage = try context.fetch(request).first
            } catch {
                Log.error("Failed to fetch message for update", category: .coreData, error: error)
                return MessageUpdateResult(
                    didUpdate: false,
                    modifiedConversationID: nil,
                    shouldInvalidateRenderedContent: false
                )
            }

            guard let existingMessage else {
                return MessageUpdateResult(
                    didUpdate: false,
                    modifiedConversationID: nil,
                    shouldInvalidateRenderedContent: false
                )
            }

            let previousWasUnread = existingMessage.isUnread
            let previousHadInboxLabel = existingMessage.labels?.contains { $0.id == "INBOX" } ?? false
            let previousSnippet = existingMessage.snippet
            let previousBodyText = existingMessage.bodyText
            let previousBodyStorageURI = existingMessage.bodyStorageURI
            let savedBodyStorageURI = processedMessage.htmlBody.flatMap {
                saveHTML($0, processedMessage.id)?.absoluteString
            }

            existingMessage.isUnread = processedMessage.isUnread
            existingMessage.isNewsletter = processedMessage.isNewsletter
            existingMessage.snippet = processedMessage.snippet
            existingMessage.cleanedSnippet = processedMessage.cleanedSnippet

            if let plainText = processedMessage.plainTextBody, !plainText.isEmpty {
                existingMessage.bodyText = plainText
            }

            if let savedBodyStorageURI {
                existingMessage.bodyStorageURI = savedBodyStorageURI
            }

            let messageLabelIds = Set(processedMessage.labelIds)
            let currentHasInboxLabel = messageLabelIds.contains("INBOX")
            existingMessage.labels = nil
            let labelCache = self.fetchLabelsByIds(messageLabelIds, in: context)
            for labelId in processedMessage.labelIds {
                if let label = labelCache[labelId] {
                    existingMessage.addToLabels(label)
                }
            }

            var existingAttachmentIds = Set(existingMessage.attachmentsArray.compactMap(\.id))
            var existingContentIds = Set(
                existingMessage.attachmentsArray.compactMap { self.normalizedContentID($0.contentId) }
            )
            var consumedOptimisticAttachmentObjectIDs = Set<NSManagedObjectID>()

            for attachmentInfo in processedMessage.attachmentInfo {
                if let optimisticAttachment = self.matchingOptimisticLocalAttachment(
                    for: attachmentInfo,
                    in: existingMessage.attachmentsArray,
                    excluding: consumedOptimisticAttachmentObjectIDs
                ) {
                    let previousAttachmentID = optimisticAttachment.id
                    self.reconcileOptimisticLocalAttachment(optimisticAttachment, with: attachmentInfo)
                    consumedOptimisticAttachmentObjectIDs.insert(optimisticAttachment.objectID)

                    if let previousAttachmentID {
                        existingAttachmentIds.remove(previousAttachmentID)
                    }
                    existingAttachmentIds.insert(attachmentInfo.id)
                    if let normalizedIncomingCID = self.normalizedContentID(attachmentInfo.contentId) {
                        existingContentIds.insert(normalizedIncomingCID)
                    }
                    continue
                }

                if existingAttachmentIds.contains(attachmentInfo.id) {
                    continue
                }

                if let normalizedIncomingCID = self.normalizedContentID(attachmentInfo.contentId),
                   existingContentIds.contains(normalizedIncomingCID) {
                    continue
                }

                self.createAttachment(attachmentInfo, for: existingMessage, in: context)

                existingAttachmentIds.insert(attachmentInfo.id)
                if let normalizedIncomingCID = self.normalizedContentID(attachmentInfo.contentId) {
                    existingContentIds.insert(normalizedIncomingCID)
                }
            }

            var modifiedConversationID: NSManagedObjectID?
            if let conversation = existingMessage.conversation {
                self.applyFastConversationListUpdateForExistingMessage(
                    existingMessage,
                    in: conversation,
                    previousHadInboxLabel: previousHadInboxLabel,
                    previousWasUnread: previousWasUnread,
                    currentHasInboxLabel: currentHasInboxLabel,
                    currentIsUnread: processedMessage.isUnread
                )
                modifiedConversationID = conversation.objectID
            }

            let bodyStorageURIChanged = existingMessage.bodyStorageURI != previousBodyStorageURI
            let bodyTextChanged = existingMessage.bodyText != previousBodyText
            let snippetChanged = existingMessage.snippet != previousSnippet

            Log.debug("Updated existing message: \(processedMessage.id)", category: .sync)

            return MessageUpdateResult(
                didUpdate: true,
                modifiedConversationID: modifiedConversationID,
                shouldInvalidateRenderedContent: bodyStorageURIChanged || bodyTextChanged || snippetChanged
            )
        }

        if let modifiedConversationID = result.modifiedConversationID {
            await ModificationTracker.shared.trackModifiedConversation(modifiedConversationID)
        }

        if result.shouldInvalidateRenderedContent {
            await ProcessedTextCache.shared.invalidate(messageId: processedMessage.id)
            HTMLContentLoader.shared.invalidate(messageId: processedMessage.id)
        }

        return result.didUpdate
    }

    nonisolated func matchingOptimisticLocalAttachment(
        for attachmentInfo: AttachmentInfo,
        in attachments: [Attachment],
        excluding excludedObjectIDs: Set<NSManagedObjectID>
    ) -> Attachment? {
        let localCandidates = attachments.filter {
            $0.isLocalAttachment && !excludedObjectIDs.contains($0.objectID)
        }

        guard !localCandidates.isEmpty else { return nil }

        if let normalizedIncomingCID = normalizedContentID(attachmentInfo.contentId),
           let cidMatch = localCandidates.first(where: {
               normalizedContentID($0.contentId) == normalizedIncomingCID
           }) {
            return cidMatch
        }

        let normalizedIncomingFilename = normalizedAttachmentFilename(attachmentInfo.filename)
        let incomingSize = Int64(attachmentInfo.size)

        return localCandidates.first(where: {
            normalizedContentID($0.contentId) == nil &&
            normalizedAttachmentFilename($0.filename) == normalizedIncomingFilename &&
            $0.mimeType == attachmentInfo.mimeType &&
            $0.byteSize == incomingSize
        })
    }

    nonisolated func reconcileOptimisticLocalAttachment(_ attachment: Attachment, with attachmentInfo: AttachmentInfo) {
        attachment.id = attachmentInfo.id
        attachment.filename = attachmentInfo.filename
        attachment.mimeType = attachmentInfo.mimeType
        attachment.contentId = attachmentInfo.contentId

        if attachmentInfo.size > 0 {
            attachment.byteSize = Int64(attachmentInfo.size)
        }
    }

    nonisolated func normalizedAttachmentFilename(_ filename: String) -> String {
        filename.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    nonisolated func normalizedContentID(_ rawValue: String?) -> String? {
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
