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

    /// Converts an Attachment entity to AttachmentInfo for sending.
    /// Updates the attachment state to uploading.
    func attachmentToInfo(_ attachment: Attachment) -> AttachmentInfo {
        // Update attachment state to uploading (will be marked as uploaded after successful send)
        attachment.state = .uploading

        return AttachmentInfo(
            localURL: attachment.localURLValue,
            filename: attachment.filenameValue,
            mimeType: attachment.mimeTypeValue
        )
    }

    /// Marks attachments as successfully uploaded.
    func markAttachmentsAsUploaded(_ attachments: [Attachment]) {
        for attachment in attachments {
            attachment.state = .uploaded
        }
        do {
            try CoreDataStack.shared.save(context: viewContext)
        } catch {
            Log.error("Failed to save attachment state", category: .attachment, error: error)
        }
    }

    /// Marks attachments as failed to upload.
    func markAttachmentsAsFailed(_ attachments: [Attachment]) {
        for attachment in attachments {
            attachment.state = .failed
        }
        do {
            try CoreDataStack.shared.save(context: viewContext)
        } catch {
            Log.error("Failed to save attachment state", category: .attachment, error: error)
        }
    }
}
