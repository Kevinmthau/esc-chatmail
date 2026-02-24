import Foundation
import CoreData

// MARK: - Helper Methods

extension MessagePersister {

    /// Creates an attachment entity using AttachmentFactory.
    func createAttachment(
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

    private func persistInlineAttachmentData(
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
        return true
    }

    /// Finds an existing conversation for a Gmail thread by looking up any already-persisted message
    /// with the same `gmThreadId`.
    ///
    /// This prevents a single Gmail thread from being split into multiple chats when the participant
    /// set differs between messages (common with `Reply-To` aliases).
    func findExistingConversation(
        forGmThreadId gmThreadId: String,
        in context: NSManagedObjectContext
    ) -> Conversation? {
        guard !gmThreadId.isEmpty else { return nil }

        let request = Message.fetchRequest()
        request.predicate = NSPredicate(format: "gmThreadId == %@ AND conversation != nil", gmThreadId)
        request.fetchLimit = 1
        request.fetchBatchSize = 1
        request.returnsObjectsAsFaults = true
        request.relationshipKeyPathsForPrefetching = ["conversation"]

        do {
            return try context.fetch(request).first?.conversation
        } catch {
            Log.error("Failed to fetch existing conversation for gmThreadId \(gmThreadId.prefix(16))...", category: .coreData, error: error)
            return nil
        }
    }

    /// Finds a label by ID.
    func findLabel(id: String, in context: NSManagedObjectContext) async -> Label? {
        let request = Label.fetchRequest()
        request.predicate = LabelPredicates.id(id)
        do {
            let label = try context.fetch(request).first
            if label == nil {
                // Log missing labels for debugging - this can happen if labels haven't been synced yet
                Log.debug("Label '\(id)' not found in local cache", category: .sync)
            }
            return label
        } catch {
            Log.error("Error fetching label '\(id)'", category: .sync, error: error)
            return nil
        }
    }

    /// Applies list-critical rollup fields immediately when a new message is created.
    /// This allows the conversation row (blue dot + preview text) to update before the
    /// full rollup phase runs later in sync.
    func applyFastConversationListUpdateForNewMessage(
        _ message: Message,
        in conversation: Conversation,
        hasInboxLabel: Bool
    ) {
        // Keep latest message preview/date current so row text updates immediately.
        if let existingLastDate = conversation.lastMessageDate {
            if message.internalDate >= existingLastDate {
                conversation.lastMessageDate = message.internalDate
                conversation.snippet = message.conversationPreviewText
            }
        } else {
            conversation.lastMessageDate = message.internalDate
            conversation.snippet = message.conversationPreviewText
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
        if conversation.archivedAt != nil {
            conversation.archivedAt = nil
        }
        if conversation.hidden {
            conversation.hidden = false
        }
    }

    /// Applies list-critical rollup fields immediately when an existing message is updated.
    /// Falls back to a scoped inbox recomputation when INBOX membership changes.
    func applyFastConversationListUpdateForExistingMessage(
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

            if conversation.archivedAt != nil {
                conversation.archivedAt = nil
            }
            if conversation.hidden {
                conversation.hidden = false
            }
        } else if previousHadInboxLabel {
            // This message left INBOX; recompute inbox-only indicators for correctness.
            refreshConversationInboxIndicators(conversation)
        }

        if let existingLastDate = conversation.lastMessageDate {
            if message.internalDate >= existingLastDate {
                conversation.lastMessageDate = message.internalDate
                conversation.snippet = message.conversationPreviewText
            }
        } else {
            conversation.lastMessageDate = message.internalDate
            conversation.snippet = message.conversationPreviewText
        }
    }

    /// Recomputes inbox-specific conversation indicators from the conversation's message set.
    private func refreshConversationInboxIndicators(_ conversation: Conversation) {
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

    /// Tracks a conversation as modified for rollup updates.
    /// Delegates to the shared ModificationTracker for consolidated tracking.
    func trackModifiedConversation(_ conversation: Conversation) async {
        await ModificationTracker.shared.trackModifiedConversation(conversation.objectID)
    }
}
