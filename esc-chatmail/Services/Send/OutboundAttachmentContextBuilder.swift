import Foundation
import CoreData

@MainActor
struct OutboundAttachmentContextBuilder {
    enum BuildError: LocalizedError, Equatable {
        case attachmentNotReady(filename: String)

        var errorDescription: String? {
            switch self {
            case .attachmentNotReady(let filename):
                return "\(filename) is still being prepared. Wait for it to finish before sending."
            }
        }
    }

    let viewContext: NSManagedObjectContext

    func buildSendAttachments(
        from attachments: [Attachment],
        including inlineAttachmentInfos: [GmailSendService.AttachmentInfo] = []
    ) throws -> [OutboundMessageRequest.AttachmentContext] {
        var inlineBytes: Int64 = 0
        for info in inlineAttachmentInfos {
            let byteCount = fileByteCount(for: info.localURL) ?? 0
            try DraftAttachmentImport.validateSize(
                byteCount: byteCount, existingByteCount: inlineBytes, filename: info.filename
            )
            inlineBytes += byteCount
        }
        try ensureAttachmentsAreReady(attachments, existingByteCount: inlineBytes)
        try ensurePermanentObjectIDs(for: attachments)

        return attachments.map { attachment in
            OutboundMessageRequest.AttachmentContext(
                info: makeAttachmentInfo(from: attachment),
                localAttachmentReference: LocalAttachmentReference(objectID: attachment.objectID)
            )
        }
    }

    func buildInlineAttachmentInfos(
        from attachments: [Attachment]
    ) throws -> [GmailSendService.AttachmentInfo] {
        try ensureAttachmentsAreReady(attachments)
        try ensurePermanentObjectIDs(for: attachments)
        return attachments.map(makeAttachmentInfo)
    }

    func buildAttachmentReferences(
        from attachments: [Attachment]
    ) throws -> [LocalAttachmentReference] {
        try ensurePermanentObjectIDs(for: attachments)
        return attachments.map { LocalAttachmentReference(objectID: $0.objectID) }
    }

    private func makeAttachmentInfo(from attachment: Attachment) -> GmailSendService.AttachmentInfo {
        GmailSendService.AttachmentInfo(
            localURL: attachment.readableLocalURLValue,
            filename: attachment.filenameValue,
            mimeType: attachment.mimeTypeValue,
            contentId: attachment.contentId
        )
    }

    private func ensureAttachmentsAreReady(_ attachments: [Attachment], existingByteCount: Int64 = 0) throws {
        var totalBytes = existingByteCount
        for attachment in attachments {
            guard let localURL = attachment.readableLocalURLValue,
                  !localURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BuildError.attachmentNotReady(filename: attachment.filenameValue)
            }
            // Stat the selected file before MIME construction, since persisted
            // metadata can be stale for forwarded/recovered attachments.
            let byteCount = fileByteCount(for: localURL) ?? attachment.byteSize
            try DraftAttachmentImport.validateSize(
                byteCount: byteCount,
                existingByteCount: totalBytes,
                filename: attachment.filenameValue
            )
            totalBytes += byteCount
        }
    }

    private func fileByteCount(for localURL: String?) -> Int64? {
        guard let url = AttachmentPaths.fullURL(for: localURL),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        return Int64(size)
    }

    private func ensurePermanentObjectIDs(for attachments: [Attachment]) throws {
        let temporaryAttachments = attachments.filter { $0.objectID.isTemporaryID }
        guard !temporaryAttachments.isEmpty else { return }

        try viewContext.obtainPermanentIDs(for: temporaryAttachments)
        viewContext.processPendingChanges()
    }
}
