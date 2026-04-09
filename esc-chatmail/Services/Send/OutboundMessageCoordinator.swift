import Foundation
import CoreData

enum OutboundMessageRequest {
    case compose(Compose)
    case forward(Forward)
    case reply(Reply)

    struct ExistingConversationContext {
        let objectURI: String
    }

    struct AttachmentContext {
        let info: GmailSendService.AttachmentInfo
        let localStateAttachmentURI: String
    }

    struct ReplyContext {
        let recipientEmails: [String]
        let subject: String?
        let threadId: String?
        let inReplyTo: String?
        let references: [String]
        let originalMessage: QuotedMessage?
        let existingConversation: ExistingConversationContext?
    }

    struct Compose {
        let recipientEmails: [String]
        let subject: String?
        let body: String
        let attachments: [AttachmentContext]
    }

    struct Forward {
        let recipientEmails: [String]
        let subject: String?
        let body: String
        let attachments: [AttachmentContext]
        let forwardedPlainTextBody: String
        let forwardedHTMLBody: String?
        let forwardedInlineAttachmentInfos: [GmailSendService.AttachmentInfo]
    }

    struct Reply {
        let context: ReplyContext
        let body: String
        let attachments: [AttachmentContext]
    }
}

struct OutboundMessageResult {
    let optimisticMessageID: String
    let conversationObjectURI: String?
}

struct OutboundMessageReconciliationHooks: Sendable {
    struct Success: Sendable {
        let optimisticMessageID: String
        let sentMessageID: String
        let threadID: String
    }

    struct Failure: Sendable {
        let optimisticMessageID: String
        let errorDescription: String
    }

    let onSuccess: (@Sendable @MainActor (Success) -> Void)?
    let onFailure: (@Sendable @MainActor (Failure) -> Void)?

    static let none = Self(onSuccess: nil, onFailure: nil)
}

@MainActor
protocol OutboundMessageCoordinating: AnyObject {
    func send(
        _ request: OutboundMessageRequest,
        reconciliationHooks: OutboundMessageReconciliationHooks
    ) async throws -> OutboundMessageResult?
}

extension OutboundMessageCoordinating {
    func send(_ request: OutboundMessageRequest) async throws -> OutboundMessageResult? {
        try await send(request, reconciliationHooks: .none)
    }
}

protocol OutboundMessageSendServicing: ComposeSendServicing {
    @MainActor
    func createOptimisticMessage(
        to recipients: [String],
        body: String,
        subject: String?,
        threadId: String?,
        attachments: [OutboundMessageRequest.AttachmentContext],
        existingConversation: OutboundMessageRequest.ExistingConversationContext?
    ) async throws -> Message

    @MainActor
    func markAttachmentsAsUploading(
        uris: [String]
    )
}

extension GmailSendService: OutboundMessageSendServicing {}

@MainActor
final class OutboundMessageCoordinator: OutboundMessageCoordinating {
    private struct PreparedSend {
        let recipientEmails: [String]
        let body: String
        let subject: String?
        let htmlBody: String?
        let threadId: String?
        let attachments: [OutboundMessageRequest.AttachmentContext]
        let inlineAttachmentInfos: [GmailSendService.AttachmentInfo]
        let existingConversation: OutboundMessageRequest.ExistingConversationContext?
        let replyData: ComposeSendOrchestrator.SendInput.ReplyData?
    }

    private let sendService: any OutboundMessageSendServicing
    private let syncPerformer: IncrementalSyncPerforming
    private let messageFormatBuilder: MessageFormatBuilder
    private let mutationTracker: any OutboundSendMutationTracking
    private var backgroundSendTasks: [String: Task<Void, Never>] = [:]

    init(
        sendService: any OutboundMessageSendServicing,
        syncPerformer: IncrementalSyncPerforming,
        messageFormatBuilder: MessageFormatBuilder,
        mutationTracker: any OutboundSendMutationTracking
    ) {
        self.sendService = sendService
        self.syncPerformer = syncPerformer
        self.messageFormatBuilder = messageFormatBuilder
        self.mutationTracker = mutationTracker
    }

    func send(
        _ request: OutboundMessageRequest,
        reconciliationHooks: OutboundMessageReconciliationHooks = .none
    ) async throws -> OutboundMessageResult? {
        let preparedSend = try prepare(request)
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
        let optimisticMessageID = optimisticMessage.id
        mutationTracker.trackPendingMutation(
            .init(
                optimisticMessageID: optimisticMessageID,
                conversationObjectID: optimisticMessage.conversation?.objectID
            )
        )
        if !preparedSend.attachments.isEmpty {
            sendService.markAttachmentsAsUploading(
                uris: preparedSend.attachments.map(\.localStateAttachmentURI)
            )
        }

        let sendInput = ComposeSendOrchestrator.SendInput(
            recipientEmails: preparedSend.recipientEmails,
            body: preparedSend.body,
            htmlBody: preparedSend.htmlBody,
            subject: preparedSend.subject,
            attachmentInfos: preparedSend.attachments.map(\.info),
            inlineAttachmentInfos: preparedSend.inlineAttachmentInfos,
            replyData: preparedSend.replyData
        )

        let effectiveHooks = makeReconciliationHooks(reconciliationHooks)
        let backgroundTask = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: syncPerformer
        ).executeInBackground(
            input: sendInput,
            attachmentObjectURIs: preparedSend.attachments.map(\.localStateAttachmentURI),
            optimisticMessageID: optimisticMessageID,
            reconciliationHooks: effectiveHooks
        )

        backgroundSendTasks[optimisticMessageID] = backgroundTask
        Task { [weak self] in
            _ = await backgroundTask.result
            await MainActor.run {
                _ = self?.backgroundSendTasks.removeValue(forKey: optimisticMessageID)
            }
        }

        return OutboundMessageResult(
            optimisticMessageID: optimisticMessageID,
            conversationObjectURI: optimisticMessage.conversation?.objectID.uriRepresentation().absoluteString
        )
    }

    private func prepare(_ request: OutboundMessageRequest) throws -> PreparedSend {
        switch request {
        case .compose(let compose):
            return PreparedSend(
                recipientEmails: compose.recipientEmails,
                body: normalizedBody(compose.body),
                subject: normalizedSubject(compose.subject),
                htmlBody: nil,
                threadId: nil,
                attachments: compose.attachments,
                inlineAttachmentInfos: [],
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
                inlineAttachmentInfos: forward.forwardedInlineAttachmentInfos,
                existingConversation: nil,
                replyData: nil
            )

        case .reply(let reply):
            let body = normalizedBody(reply.body)

            return PreparedSend(
                recipientEmails: reply.context.recipientEmails,
                body: body,
                subject: reply.context.subject,
                htmlBody: nil,
                threadId: reply.context.threadId,
                attachments: reply.attachments,
                inlineAttachmentInfos: [],
                existingConversation: reply.context.existingConversation,
                replyData: .init(
                    recipients: reply.context.recipientEmails,
                    body: body,
                    subject: reply.context.subject,
                    threadId: reply.context.threadId,
                    inReplyTo: reply.context.inReplyTo,
                    references: reply.context.references,
                    originalMessage: reply.context.originalMessage
                )
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

    private func makeReconciliationHooks(
        _ externalHooks: OutboundMessageReconciliationHooks
    ) -> OutboundMessageReconciliationHooks {
        OutboundMessageReconciliationHooks(
            onSuccess: { [weak mutationTracker] success in
                mutationTracker?.reconcileSuccess(success)
                externalHooks.onSuccess?(success)
            },
            onFailure: { [weak mutationTracker] failure in
                mutationTracker?.reconcileFailure(failure)
                externalHooks.onFailure?(failure)
            }
        )
    }
}
