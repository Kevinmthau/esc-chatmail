import Foundation
import CoreData

// MARK: - Message Updates

private struct MessageUpdateResult {
    let didUpdate: Bool
    let modifiedConversationID: NSManagedObjectID?
    let shouldInvalidateRenderedContent: Bool
    let participantDisplayNameUpdateEmails: [String]
    let participantDisplayNameUpdateConversationIDs: Set<NSManagedObjectID>
}

extension MessagePersister {

    /// Updates an existing message if it exists.
    /// - Returns: true if an existing message was found and updated
    func updateExistingMessage(
        _ processedMessage: ProcessedMessage,
        labelIds: Set<String>?,
        modificationTransaction: ModificationTracker.Transaction? = nil,
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
                    shouldInvalidateRenderedContent: false,
                    participantDisplayNameUpdateEmails: [],
                    participantDisplayNameUpdateConversationIDs: []
                )
            }

            guard let existingMessage else {
                return MessageUpdateResult(
                    didUpdate: false,
                    modifiedConversationID: nil,
                    shouldInvalidateRenderedContent: false,
                    participantDisplayNameUpdateEmails: [],
                    participantDisplayNameUpdateConversationIDs: []
                )
            }

            let previousWasUnread = existingMessage.isUnread
            let previousHadInboxLabel = existingMessage.labels?.contains { $0.id == "INBOX" } ?? false
            let previousSnippet = existingMessage.snippet
            let previousBodyText = existingMessage.bodyText
            let previousChatPreviewText = existingMessage.chatPreviewText
            let previousBodyStorageURI = existingMessage.bodyStorageURI
            let previousSenderEmail = existingMessage.senderEmail
            let previousSenderName = existingMessage.senderName
            let previousIsFromMe = existingMessage.isFromMe
            var senderHeaderDisplayNameUpdateEmails = Set<String>()
            var senderHeaderDisplayNameUpdateConversationIDs = Set<NSManagedObjectID>()
            let shouldPreserveLocalMailboxState = HistoryProcessor.hasPendingLocalModification(message: existingMessage)
            let canonicalHTML = processedMessage.canonicalContent?.html ?? processedMessage.htmlBody
            let savedBodyStorageURI = canonicalHTML.flatMap {
                saveHTML($0, processedMessage.id)?.absoluteString
            }

            existingMessage.gmThreadId = processedMessage.gmThreadId
            existingMessage.subject = processedMessage.headers.subject
            existingMessage.isFromMe = processedMessage.headers.isFromMe
            existingMessage.isNewsletter = processedMessage.isNewsletter
            existingMessage.hasAttachments = processedMessage.hasAttachments
            existingMessage.snippet = processedMessage.snippet
            existingMessage.cleanedSnippet = processedMessage.cleanedSnippet
            existingMessage.chatPreviewText = processedMessage.chatPreviewText
            existingMessage.setValue(processedMessage.headers.messageId, forKey: "messageId")
            existingMessage.setValue(
                processedMessage.headers.references.isEmpty ? nil : processedMessage.headers.references.joined(separator: " "),
                forKey: "references"
            )

            if let from = processedMessage.headers.from {
                var normalizedSenderEmail = previousSenderEmail.map(EmailNormalizer.normalize) ?? ""
                if let email = EmailNormalizer.extractEmail(from: from) {
                    existingMessage.setValue(email, forKey: "senderEmail")
                    normalizedSenderEmail = EmailNormalizer.normalize(email)
                }
                let displayName = EmailNormalizer.extractDisplayName(from: from)
                existingMessage.setValue(displayName, forKey: "senderName")

                let previousNormalizedSenderEmail = previousSenderEmail.map(EmailNormalizer.normalize) ?? ""
                let senderHeaderChanged = displayName != previousSenderName ||
                    normalizedSenderEmail != previousNormalizedSenderEmail
                if senderHeaderChanged {
                    for email in [previousNormalizedSenderEmail, normalizedSenderEmail] where !email.isEmpty {
                        senderHeaderDisplayNameUpdateEmails.insert(email)
                    }
                    if let conversationID = existingMessage.conversation?.objectID {
                        senderHeaderDisplayNameUpdateConversationIDs.insert(conversationID)
                    }
                }
            }

            if let plainText = processedMessage.plainTextBody, !plainText.isEmpty {
                let shouldPreserveOutgoingLocalBody = self.shouldPreserveOutgoingLocalBodyText(
                    previousBodyText: previousBodyText,
                    incomingBodyText: plainText,
                    incomingSnippet: processedMessage.snippet,
                    incomingCleanedSnippet: processedMessage.cleanedSnippet,
                    wasFromMe: previousIsFromMe,
                    isFromMe: processedMessage.headers.isFromMe
                )
                if shouldPreserveOutgoingLocalBody {
                    Log.debug(
                        "Preserving local outgoing body text for message \(processedMessage.id) over snippet-only sync body",
                        category: .sync
                    )
                } else {
                    existingMessage.bodyText = plainText
                }
            }

            let participantDisplayNameUpdate = self.updateKnownParticipantDisplayNames(
                from: processedMessage.headers,
                in: context
            )
            let displayNameUpdateEmails = Array(
                Set(participantDisplayNameUpdate.emails)
                    .union(senderHeaderDisplayNameUpdateEmails)
            )
            PersonDisplayInfoChangeNotification.invalidatePersonCacheAndPostAfterContextSave(
                emails: displayNameUpdateEmails,
                in: context
            )
            let displayNameUpdateConversationIDs = participantDisplayNameUpdate.conversationIDs
                .union(senderHeaderDisplayNameUpdateConversationIDs)

            if let savedBodyStorageURI {
                existingMessage.bodyStorageURI = savedBodyStorageURI
            }

            let messageLabelIds = Set(processedMessage.labelIds)
            if shouldPreserveLocalMailboxState {
                Log.debug(
                    "Preserving local mailbox state for message \(processedMessage.id) while pending action exists",
                    category: .sync
                )
            } else {
                existingMessage.isUnread = processedMessage.isUnread
                existingMessage.labels = nil
                let availableLabelIds = labelIds.map { messageLabelIds.intersection($0) } ?? messageLabelIds
                let effectiveLabelCache = self.fetchLabelsByIds(availableLabelIds, in: context)
                for labelId in processedMessage.labelIds {
                    if let label = effectiveLabelCache[labelId] {
                        existingMessage.addToLabels(label)
                    }
                }
            }
            let currentHasInboxLabel = existingMessage.labels?.contains { $0.id == "INBOX" } ?? false

            var existingAttachmentIds = Set(existingMessage.attachmentsArray.compactMap(\.id))
            var existingContentIds = Set(
                existingMessage.attachmentsArray.compactMap { self.normalizedContentID($0.contentId) }
            )
            var consumedOptimisticAttachmentObjectIDs = Set<NSManagedObjectID>()

            // Remove duplicate inline attachments left by earlier syncs that
            // used non-deterministic (UUID-based) IDs.
            self.deduplicateInlineAttachments(on: existingMessage, in: context)
            context.processPendingChanges()

            // Rebuild after dedup so the sets reflect current state.
            existingAttachmentIds = Set(existingMessage.attachmentsArray.compactMap(\.id))

            // Build fingerprint set for inline-data attachments to prevent
            // re-adding the same content under a new deterministic ID.
            var existingInlineFingerprints = Set<String>()
            for attachment in existingMessage.attachmentsArray {
                let fp = self.inlineAttachmentFingerprint(attachment)
                if let fp { existingInlineFingerprints.insert(fp) }
            }

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

                // Skip inline attachments that match an existing one by
                // filename + mimeType + size (covers old UUID-based IDs).
                let incomingFP = self.inlineAttachmentFingerprint(for: attachmentInfo)
                if let incomingFP, existingInlineFingerprints.contains(incomingFP) {
                    continue
                }

                self.createAttachment(attachmentInfo, for: existingMessage, in: context)

                existingAttachmentIds.insert(attachmentInfo.id)
                if let normalizedIncomingCID = self.normalizedContentID(attachmentInfo.contentId) {
                    existingContentIds.insert(normalizedIncomingCID)
                }
                if let incomingFP { existingInlineFingerprints.insert(incomingFP) }
            }
            existingMessage.hasAttachments = !existingMessage.attachmentsArray.isEmpty || processedMessage.hasAttachments

            var modifiedConversationID: NSManagedObjectID?
            if let conversation = existingMessage.conversation {
                self.applyFastConversationListUpdateForExistingMessage(
                    existingMessage,
                    in: conversation,
                    previousHadInboxLabel: previousHadInboxLabel,
                    previousWasUnread: previousWasUnread,
                    currentHasInboxLabel: currentHasInboxLabel,
                    currentIsUnread: existingMessage.isUnread
                )
                modifiedConversationID = conversation.objectID
            }

            let bodyStorageURIChanged = existingMessage.bodyStorageURI != previousBodyStorageURI
            let bodyTextChanged = existingMessage.bodyText != previousBodyText
            let chatPreviewTextChanged = existingMessage.chatPreviewText != previousChatPreviewText
            let snippetChanged = existingMessage.snippet != previousSnippet

            Log.debug("Updated existing message: \(processedMessage.id)", category: .sync)

            return MessageUpdateResult(
                didUpdate: true,
                modifiedConversationID: modifiedConversationID,
                shouldInvalidateRenderedContent: bodyStorageURIChanged || bodyTextChanged || chatPreviewTextChanged || snippetChanged,
                participantDisplayNameUpdateEmails: displayNameUpdateEmails,
                participantDisplayNameUpdateConversationIDs: displayNameUpdateConversationIDs
            )
        }

        if let modifiedConversationID = result.modifiedConversationID {
            await ModificationTracker.shared.trackModifiedConversation(
                modifiedConversationID,
                in: modificationTransaction
            )
        }

        var displayNameOnlyConversationIDs = result.participantDisplayNameUpdateConversationIDs
        if let modifiedConversationID = result.modifiedConversationID {
            displayNameOnlyConversationIDs.remove(modifiedConversationID)
        }
        await ModificationTracker.shared.trackDisplayNameOnlyConversations(
            displayNameOnlyConversationIDs,
            in: modificationTransaction
        )

        if result.shouldInvalidateRenderedContent {
            await ProcessedTextCache.shared.invalidate(messageId: processedMessage.id)
            HTMLContentLoader.shared.invalidate(messageId: processedMessage.id)
        }

        return result.didUpdate
    }

    private func shouldPreserveOutgoingLocalBodyText(
        previousBodyText: String?,
        incomingBodyText: String,
        incomingSnippet: String?,
        incomingCleanedSnippet: String?,
        wasFromMe: Bool,
        isFromMe: Bool
    ) -> Bool {
        guard wasFromMe, isFromMe,
              let previous = normalizedBodyComparisonText(previousBodyText),
              let incoming = normalizedBodyComparisonText(incomingBodyText),
              previous.count > incoming.count,
              previous.hasPrefix(incoming) else {
            return false
        }

        let snippetCandidates = [incomingSnippet, incomingCleanedSnippet]
            .compactMap(normalizedBodyComparisonText)
        guard !snippetCandidates.isEmpty else {
            return false
        }

        return snippetCandidates.contains(incoming)
    }

    private func normalizedBodyComparisonText(_ text: String?) -> String? {
        guard let text else { return nil }

        let normalized = HTMLEntityDecoder.decode(
            RawEmailSourceSanitizer.extractDisplayText(from: text)
        )
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")

        return normalized.isEmpty ? nil : normalized
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

    // MARK: - Inline attachment deduplication

    /// Fingerprint for an existing Core Data attachment (filename|mimeType).
    nonisolated func inlineAttachmentFingerprint(_ attachment: Attachment) -> String? {
        guard let id = attachment.id, id.hasPrefix("local_inline_") else { return nil }
        let filename = normalizedAttachmentFilename(attachment.filename)
        let mimeType = attachment.mimeType
        return "\(filename)|\(mimeType)"
    }

    /// Fingerprint for an incoming AttachmentInfo.
    nonisolated func inlineAttachmentFingerprint(for info: AttachmentInfo) -> String? {
        guard info.id.hasPrefix("local_inline_") else { return nil }
        let filename = normalizedAttachmentFilename(info.filename)
        return "\(filename)|\(info.mimeType)"
    }

    /// Removes duplicate inline attachments, keeping only the first per fingerprint.
    nonisolated func deduplicateInlineAttachments(on message: Message, in context: NSManagedObjectContext) {
        autoreleasepool {
            var bestAttachmentByContentID: [String: Attachment] = [:]

            for attachment in message.attachmentsArray {
                guard let contentID = normalizedContentID(attachment.contentId) else { continue }

                if let existing = bestAttachmentByContentID[contentID] {
                    if shouldPreferInlineAttachment(attachment, over: existing) {
                        context.delete(existing)
                        bestAttachmentByContentID[contentID] = attachment
                    } else {
                        context.delete(attachment)
                    }
                } else {
                    bestAttachmentByContentID[contentID] = attachment
                }
            }

            var seen = Set<String>()
            for attachment in message.attachmentsArray {
                if attachment.isDeleted {
                    continue
                }
                guard let fp = inlineAttachmentFingerprint(attachment) else { continue }
                if seen.contains(fp) {
                    context.delete(attachment)
                } else {
                    seen.insert(fp)
                }
            }
        }
    }

    nonisolated func shouldPreferInlineAttachment(_ lhs: Attachment, over rhs: Attachment) -> Bool {
        inlineAttachmentRetentionScore(lhs) > inlineAttachmentRetentionScore(rhs)
    }

    nonisolated func inlineAttachmentRetentionScore(_ attachment: Attachment) -> Int {
        var score = 0

        if !(attachment.id?.hasPrefix("local_inline_") ?? false) {
            score += 8
        }
        if attachment.localURL != nil {
            score += 16
        }
        if attachment.previewURL != nil {
            score += 8
        }
        if attachment.isReady {
            score += 4
        }
        if attachment.byteSize > 0 {
            score += 2
        }

        return score
    }
}
