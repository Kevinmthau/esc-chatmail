import Foundation
import CoreData

@MainActor
struct OutboundAttachmentContextBuilder {
    let viewContext: NSManagedObjectContext

    func buildSendAttachments(
        from attachments: [Attachment]
    ) throws -> [OutboundMessageRequest.AttachmentContext] {
        try ensurePermanentObjectIDs(for: attachments)

        return attachments.map { attachment in
            OutboundMessageRequest.AttachmentContext(
                info: makeAttachmentInfo(from: attachment),
                localStateAttachmentURI: attachment.objectID.uriRepresentation().absoluteString
            )
        }
    }

    func buildInlineAttachmentInfos(
        from attachments: [Attachment]
    ) throws -> [GmailSendService.AttachmentInfo] {
        try ensurePermanentObjectIDs(for: attachments)
        return attachments.map(makeAttachmentInfo)
    }

    private func makeAttachmentInfo(from attachment: Attachment) -> GmailSendService.AttachmentInfo {
        GmailSendService.AttachmentInfo(
            localURL: attachment.localURLValue,
            filename: attachment.filenameValue,
            mimeType: attachment.mimeTypeValue,
            contentId: attachment.contentId
        )
    }

    private func ensurePermanentObjectIDs(for attachments: [Attachment]) throws {
        let temporaryAttachments = attachments.filter { $0.objectID.isTemporaryID }
        guard !temporaryAttachments.isEmpty else { return }

        try viewContext.obtainPermanentIDs(for: temporaryAttachments)
        viewContext.processPendingChanges()
    }
}
