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

    /// Tracks a conversation as modified for rollup updates.
    /// Delegates to the shared ModificationTracker for consolidated tracking.
    func trackModifiedConversation(_ conversation: Conversation) async {
        await ModificationTracker.shared.trackModifiedConversation(conversation.objectID)
    }
}
