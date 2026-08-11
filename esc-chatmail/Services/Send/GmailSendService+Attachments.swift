import Foundation
import CoreData

// MARK: - Attachment Handling

extension GmailSendService {

    /// Prepares attachment data for sending by loading content from local URLs.
    func prepareAttachmentInfos(_ attachmentInfos: [AttachmentInfo]) async throws -> [AttachmentData] {
        var attachmentData: [AttachmentData] = []

        for info in attachmentInfos {
            guard let data = AttachmentPaths.loadData(from: info.localURL) else {
                throw SendError.apiError("Failed to load attachment: \(info.filename)")
            }

            attachmentData.append(AttachmentData(
                data: data,
                filename: info.filename,
                mimeType: info.mimeType
            ))
        }

        return attachmentData
    }

    /// Prepares inline attachment data for sending by loading content from local URLs.
    /// Only processes attachments that have both localURL and contentId.
    func prepareInlineAttachmentInfos(_ attachmentInfos: [AttachmentInfo]) async throws -> [InlineAttachmentData] {
        var inlineData: [InlineAttachmentData] = []

        for info in attachmentInfos {
            // Skip if no contentId (not an inline attachment)
            guard let contentId = info.contentId, !contentId.isEmpty else {
                continue
            }

            // Skip if no local data available (attachment not downloaded)
            guard let data = AttachmentPaths.loadData(from: info.localURL) else {
                Log.warning("Skipping inline attachment \(info.filename) - file not downloaded", category: .attachment)
                continue
            }

            inlineData.append(InlineAttachmentData(
                data: data,
                contentId: contentId,
                filename: info.filename,
                mimeType: info.mimeType
            ))
        }

        return inlineData
    }

    /// Converts an Attachment entity to AttachmentInfo for sending.
    /// Updates the attachment state to uploading.
    func attachmentToInfo(_ attachment: Attachment) -> AttachmentInfo {
        // Update attachment state to uploading (will be marked as uploaded after successful send)
        attachment.state = .uploading
        return attachmentSnapshot(attachment)
    }

    /// Creates a read-only attachment snapshot for MIME building without mutating local send state.
    func attachmentSnapshot(_ attachment: Attachment) -> AttachmentInfo {
        AttachmentInfo(
            localURL: attachment.readableLocalURLValue,
            filename: attachment.filenameValue,
            mimeType: attachment.mimeTypeValue,
            contentId: attachment.contentId
        )
    }

    /// Marks attachments as successfully uploaded.
    @MainActor
    func markAttachmentsAsUploading(references: [LocalAttachmentReference]) {
        let attachments = resolveAttachmentsForStateUpdate(from: references)
        guard !attachments.isEmpty else { return }

        for attachment in attachments {
            attachment.state = Attachment.State.uploading
        }
    }

    @MainActor
    func markAttachmentsAsUploaded(references: [LocalAttachmentReference]) {
        let attachments = resolveAttachmentsForStateUpdate(from: references)
        guard !attachments.isEmpty else { return }

        markAttachmentsAsUploaded(attachments)
    }

    @MainActor
    func markAttachmentsAsUploaded(_ attachments: [Attachment]) {
        for attachment in attachments {
            attachment.state = .uploaded
        }
        do {
            if viewContext.hasChanges {
                try viewContext.save()
            }
        } catch {
            Log.error("Failed to save attachment state", category: .attachment, error: error)
        }
    }

    /// Marks attachments as failed to upload.
    @MainActor
    func markAttachmentsAsFailed(_ attachments: [Attachment]) {
        for attachment in attachments {
            attachment.state = .failed
        }
        do {
            if viewContext.hasChanges {
                try viewContext.save()
            }
        } catch {
            Log.error("Failed to save attachment state", category: .attachment, error: error)
        }
    }

    @MainActor
    private func resolveAttachmentsForStateUpdate(
        from references: [LocalAttachmentReference]
    ) -> [Attachment] {
        references.compactMap { reference in
            guard let objectID = reference.resolveObjectID(in: viewContext) else {
                return nil
            }

            return try? viewContext.existingObject(with: objectID) as? Attachment
        }
    }
}
