import Foundation
import CoreData

@MainActor
protocol OutboundMessageCoordinating: AnyObject {
    func send(_ request: OutboundMessageCoordinator.Request) async throws -> OutboundMessageCoordinator.Submission?
}

protocol OutboundMessageSendServicing: ComposeSendServicing {
    @MainActor
    func createOptimisticMessage(
        to recipients: [String],
        body: String,
        subject: String?,
        threadId: String?,
        attachments: [Attachment],
        existingConversation: Conversation?
    ) async throws -> Message

    func attachmentToInfo(_ attachment: Attachment) -> GmailSendService.AttachmentInfo
}

extension GmailSendService: OutboundMessageSendServicing {}

@MainActor
final class OutboundMessageCoordinator: OutboundMessageCoordinating {
    enum Request {
        case compose(Compose)
        case forward(Forward)
        case reply(Reply)

        struct Compose {
            let recipientEmails: [String]
            let subject: String?
            let body: String
            let attachments: [Attachment]
        }

        struct Forward {
            let recipientEmails: [String]
            let subject: String?
            let body: String
            let attachments: [Attachment]
            let forwardedPlainTextBody: String
            let forwardedHTMLBody: String?
            let forwardedInlineAttachments: [Attachment]
        }

        struct Reply {
            let conversation: Conversation
            let replyingTo: Message?
            let body: String
            let attachments: [Attachment]
        }
    }

    struct Submission {
        let optimisticMessageID: String
        let conversationObjectID: NSManagedObjectID?
        let backgroundTask: Task<Void, Never>
    }

    private struct PreparedSend {
        let recipientEmails: [String]
        let body: String
        let subject: String?
        let htmlBody: String?
        let threadId: String?
        let attachments: [Attachment]
        let inlineAttachments: [Attachment]
        let existingConversation: Conversation?
        let replyData: ComposeSendOrchestrator.SendInput.ReplyData?
    }

    private let sendService: any OutboundMessageSendServicing
    private let syncPerformer: IncrementalSyncPerforming
    private let replyMetadataBuilder: ReplyMetadataBuilder
    private let messageFormatBuilder: MessageFormatBuilder

    init(
        sendService: any OutboundMessageSendServicing,
        syncPerformer: IncrementalSyncPerforming,
        replyMetadataBuilder: ReplyMetadataBuilder,
        messageFormatBuilder: MessageFormatBuilder
    ) {
        self.sendService = sendService
        self.syncPerformer = syncPerformer
        self.replyMetadataBuilder = replyMetadataBuilder
        self.messageFormatBuilder = messageFormatBuilder
    }

    func send(_ request: Request) async throws -> Submission? {
        let preparedSend = prepare(request)
        guard !preparedSend.recipientEmails.isEmpty else {
            Log.warning("Skipping outbound send with no recipients", category: .message)
            return nil
        }

        let optimisticMessage = try await sendService.createOptimisticMessage(
            to: preparedSend.recipientEmails,
            body: preparedSend.body,
            subject: preparedSend.subject,
            threadId: preparedSend.threadId,
            attachments: preparedSend.attachments,
            existingConversation: preparedSend.existingConversation
        )

        let sendInput = ComposeSendOrchestrator.SendInput(
            recipientEmails: preparedSend.recipientEmails,
            body: preparedSend.body,
            htmlBody: preparedSend.htmlBody,
            subject: preparedSend.subject,
            attachmentInfos: preparedSend.attachments.map { sendService.attachmentToInfo($0) },
            inlineAttachmentInfos: preparedSend.inlineAttachments.map { sendService.attachmentToInfo($0) },
            replyData: preparedSend.replyData
        )

        let backgroundTask = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: syncPerformer
        ).executeInBackground(
            input: sendInput,
            attachments: preparedSend.attachments,
            optimisticMessageID: optimisticMessage.id
        )

        return Submission(
            optimisticMessageID: optimisticMessage.id,
            conversationObjectID: optimisticMessage.conversation?.objectID,
            backgroundTask: backgroundTask
        )
    }

    private func prepare(_ request: Request) -> PreparedSend {
        switch request {
        case .compose(let compose):
            return PreparedSend(
                recipientEmails: compose.recipientEmails,
                body: normalizedBody(compose.body),
                subject: normalizedSubject(compose.subject),
                htmlBody: nil,
                threadId: nil,
                attachments: compose.attachments,
                inlineAttachments: [],
                existingConversation: nil,
                replyData: nil
            )

        case .forward(let forward):
            let userBody = normalizedBody(forward.body)
            let body: String
            if userBody.isEmpty {
                body = forward.forwardedPlainTextBody
            } else if forward.forwardedPlainTextBody.isEmpty {
                body = userBody
            } else {
                body = "\(userBody)\n\n\(forward.forwardedPlainTextBody)"
            }

            let htmlBody: String?
            if let forwardedHTMLBody = forward.forwardedHTMLBody {
                htmlBody = messageFormatBuilder.buildFinalHTMLForForward(
                    userContent: userBody,
                    forwardedHTML: forwardedHTMLBody
                )
            } else {
                htmlBody = messageFormatBuilder.generateHTMLFromPlainText(body)
            }

            return PreparedSend(
                recipientEmails: forward.recipientEmails,
                body: body,
                subject: normalizedSubject(forward.subject),
                htmlBody: htmlBody,
                threadId: nil,
                attachments: forward.attachments,
                inlineAttachments: forward.forwardedInlineAttachments,
                existingConversation: nil,
                replyData: nil
            )

        case .reply(let reply):
            let body = normalizedBody(reply.body)
            let replyData = replyMetadataBuilder.buildReplyData(
                conversation: reply.conversation,
                replyingTo: reply.replyingTo,
                body: body
            )

            return PreparedSend(
                recipientEmails: replyData.recipients,
                body: body,
                subject: replyData.subject,
                htmlBody: nil,
                threadId: replyData.threadId,
                attachments: reply.attachments,
                inlineAttachments: [],
                existingConversation: reply.conversation,
                replyData: ComposeSendOrchestrator.SendInput.ReplyData(replyData)
            )
        }
    }

    private func normalizedBody(_ body: String) -> String {
        body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedSubject(_ subject: String?) -> String? {
        guard let subject, !subject.isEmpty else {
            return nil
        }

        return subject
    }
}
