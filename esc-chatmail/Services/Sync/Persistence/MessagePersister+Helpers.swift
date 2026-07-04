import Foundation
import CoreData

// MARK: - Helper Methods

extension MessagePersister {

    func deleteExistingMessageIfPresent(
        id: String,
        modificationTransaction: ModificationTracker.Transaction?,
        in context: NSManagedObjectContext
    ) async {
        let modifiedConversationID: NSManagedObjectID? = await context.perform {
            let request = Message.fetchRequest()
            request.predicate = MessagePredicates.id(id)
            request.fetchLimit = 1
            request.relationshipKeyPathsForPrefetching = ["conversation"]

            do {
                guard let message = try context.fetch(request).first else {
                    return nil
                }

                let conversationID = message.conversation?.objectID
                context.delete(message)
                return conversationID
            } catch {
                Log.error("Failed to delete excluded mailbox message \(id)", category: .coreData, error: error)
                return nil
            }
        }

        if let modifiedConversationID {
            await ModificationTracker.shared.trackModifiedConversation(
                modifiedConversationID,
                in: modificationTransaction
            )
        }
    }

    /// Creates an attachment entity using AttachmentFactory.
    nonisolated func createAttachment(
        _ info: AttachmentInfo,
        for message: Message,
        in context: NSManagedObjectContext
    ) {
        do {
            let attachment = try AttachmentFactory.create(from: info, for: message, in: context)

            if let inlineData = info.inlineData {
                let didPersistInlineData = persistInlineAttachmentData(
                    inlineData,
                    info: info,
                    attachment: attachment
                )
                if !didPersistInlineData {
                    context.delete(attachment)
                    Log.warning("Dropping inline attachment for message \(message.id) due to local persistence failure", category: .attachment)
                }
            }
        } catch {
            Log.error("Failed to create attachment for message \(message.id): \(error)", category: .coreData)
        }
    }

    func scheduleInlineCIDPrefetchIfNeeded(
        for processedMessage: ProcessedMessage,
        in context: NSManagedObjectContext
    ) async {
        let request = InlineCIDAttachmentPrefetchRequest(
            messageId: processedMessage.id,
            contentIDs: processedMessage.inlineCIDPrefetchContentIDs,
            attachmentIDs: processedMessage.inlineCIDPrefetchAttachmentIDs
        )
        guard !request.isEmpty else { return }

        let scheduler = inlineCIDPrefetchScheduler
        await context.perform {
            scheduler(request, context)
        }
    }

    nonisolated func persistInlineAttachmentData(
        _ inlineData: Data,
        info: AttachmentInfo,
        attachment: Attachment
    ) -> Bool {
        AttachmentPaths.setupDirectories()

        guard let attachmentId = attachment.id, !attachmentId.isEmpty else {
            return false
        }

        let filenameExt = (info.filename as NSString).pathExtension.lowercased()
        let ext = filenameExt.isEmpty ? AttachmentPaths.fileExtension(for: info.mimeType) : filenameExt
        let originalPath = AttachmentPaths.originalPath(idOrUUID: attachmentId, ext: ext)

        guard AttachmentPaths.saveData(inlineData, to: originalPath) else {
            return false
        }

        attachment.localURL = originalPath
        attachment.byteSize = Int64(max(info.size, inlineData.count))

        if info.mimeType.hasPrefix("image/"),
           let dimensions = ImageProcessor.getImageDimensions(from: inlineData) {
            attachment.width = Int16(clamping: Int(dimensions.width.rounded()))
            attachment.height = Int16(clamping: Int(dimensions.height.rounded()))
        }

        if info.mimeType == "application/pdf",
           let pageCount = ImageProcessor.getPDFPageCount(from: inlineData) {
            attachment.pageCount = Int16(clamping: pageCount)
        }

        if let thumbnailData = ImageProcessor.generateThumbnail(from: inlineData, mimeType: info.mimeType) {
            let previewPath = AttachmentPaths.previewPath(idOrUUID: attachmentId)
            if AttachmentPaths.saveData(thumbnailData, to: previewPath) {
                attachment.previewURL = previewPath
            }
        }

        attachment.state = .downloaded
        attachment.lastDownloadFailedAt = nil
        return true
    }

    /// Applies list-critical rollup fields immediately when a new message is created.
    /// This allows the conversation row (blue dot + preview text) to update before the
    /// full rollup phase runs later in sync.
    nonisolated func applyFastConversationListUpdateForNewMessage(
        _ message: Message,
        in conversation: Conversation,
        hasInboxLabel: Bool
    ) {
        // Keep latest message preview/date current so row text updates immediately.
        if let existingLastDate = conversation.lastMessageDate {
            if message.internalDate >= existingLastDate {
                conversation.lastMessageDate = message.internalDate
                if let previewText = MessagePreviewText.nonEmpty(message.conversationPreviewText) {
                    conversation.snippet = previewText
                }
            }
        } else {
            conversation.lastMessageDate = message.internalDate
            if let previewText = MessagePreviewText.nonEmpty(message.conversationPreviewText) {
                conversation.snippet = previewText
            }
        }

        guard hasInboxLabel else { return }

        conversation.hasInbox = true
        if message.isUnread {
            conversation.inboxUnreadCount = min(Int32.max, conversation.inboxUnreadCount + 1)
        }

        if let existingLatestInboxDate = conversation.latestInboxDate {
            if message.internalDate > existingLatestInboxDate {
                conversation.latestInboxDate = message.internalDate
            }
        } else {
            conversation.latestInboxDate = message.internalDate
        }

        // New inbox mail should immediately reactivate hidden/archived threads.
        ConversationRoutingPolicy().reactivateArchivedConversationIfNeeded(
            conversation,
            shouldReactivate: true
        )
    }

    /// Applies list-critical rollup fields immediately when an existing message is updated.
    /// Falls back to a scoped inbox recomputation when INBOX membership changes.
    nonisolated func applyFastConversationListUpdateForExistingMessage(
        _ message: Message,
        in conversation: Conversation,
        previousHadInboxLabel: Bool,
        previousWasUnread: Bool,
        currentHasInboxLabel: Bool,
        currentIsUnread: Bool
    ) {
        let previousUnreadInInbox = previousHadInboxLabel && previousWasUnread
        let currentUnreadInInbox = currentHasInboxLabel && currentIsUnread

        if previousUnreadInInbox != currentUnreadInInbox {
            if currentUnreadInInbox {
                conversation.inboxUnreadCount = min(Int32.max, conversation.inboxUnreadCount + 1)
            } else {
                conversation.inboxUnreadCount = max(0, conversation.inboxUnreadCount - 1)
            }
        }

        if currentHasInboxLabel {
            conversation.hasInbox = true
            if let existingLatestInboxDate = conversation.latestInboxDate {
                if message.internalDate > existingLatestInboxDate {
                    conversation.latestInboxDate = message.internalDate
                }
            } else {
                conversation.latestInboxDate = message.internalDate
            }

            ConversationRoutingPolicy().reactivateArchivedConversationIfNeeded(
                conversation,
                shouldReactivate: true
            )
        } else if previousHadInboxLabel {
            // This message left INBOX; recompute inbox-only indicators for correctness.
            refreshConversationInboxIndicators(conversation)
        }

        if let existingLastDate = conversation.lastMessageDate {
            if message.internalDate >= existingLastDate {
                conversation.lastMessageDate = message.internalDate
                if let previewText = MessagePreviewText.nonEmpty(message.conversationPreviewText) {
                    conversation.snippet = previewText
                }
            }
        } else {
            conversation.lastMessageDate = message.internalDate
            if let previewText = MessagePreviewText.nonEmpty(message.conversationPreviewText) {
                conversation.snippet = previewText
            }
        }
    }

    /// Recomputes inbox-specific conversation indicators from the conversation's message set.
    /// Note: For best performance, prefetch "messages" and "messages.labels" on the
    /// conversation's fetch request via relationshipKeyPathsForPrefetching before calling this.
    nonisolated func refreshConversationInboxIndicators(_ conversation: Conversation) {
        // Prefetch labels for all messages to avoid N individual faults
        if let context = conversation.managedObjectContext, let messages = conversation.messages, !messages.isEmpty {
            let messageIDs = messages.compactMap { $0.objectID }
            let prefetchRequest = Message.fetchRequest()
            prefetchRequest.predicate = NSPredicate(format: "SELF IN %@", messageIDs)
            prefetchRequest.relationshipKeyPathsForPrefetching = ["labels"]
            _ = try? context.fetch(prefetchRequest)
        }

        guard let messages = conversation.messages else {
            conversation.hasInbox = false
            conversation.inboxUnreadCount = 0
            conversation.latestInboxDate = nil
            return
        }

        var hasInbox = false
        var unreadCount: Int32 = 0
        var latestInboxDate: Date?

        for message in messages {
            let isInbox = message.labels?.contains(where: { $0.id == "INBOX" }) ?? false
            guard isInbox else { continue }

            hasInbox = true
            if message.isUnread {
                unreadCount = min(Int32.max, unreadCount + 1)
            }
            if let currentLatestInboxDate = latestInboxDate {
                if message.internalDate > currentLatestInboxDate {
                    latestInboxDate = message.internalDate
                }
            } else {
                latestInboxDate = message.internalDate
            }
        }

        conversation.hasInbox = hasInbox
        conversation.inboxUnreadCount = unreadCount
        conversation.latestInboxDate = latestInboxDate
    }
}
