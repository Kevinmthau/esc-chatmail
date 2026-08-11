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
        from attachments: [Attachment]
    ) throws -> [OutboundMessageRequest.AttachmentContext] {
        try ensureAttachmentsAreReady(attachments)
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

    private func ensureAttachmentsAreReady(_ attachments: [Attachment]) throws {
        for attachment in attachments {
            guard let localURL = attachment.readableLocalURLValue,
                  !localURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BuildError.attachmentNotReady(filename: attachment.filenameValue)
            }
        }
    }

    private func ensurePermanentObjectIDs(for attachments: [Attachment]) throws {
        let temporaryAttachments = attachments.filter { $0.objectID.isTemporaryID }
        guard !temporaryAttachments.isEmpty else { return }

        try viewContext.obtainPermanentIDs(for: temporaryAttachments)
        viewContext.processPendingChanges()
    }
}
