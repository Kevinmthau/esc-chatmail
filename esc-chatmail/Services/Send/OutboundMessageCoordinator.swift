import Foundation
import CoreData

enum OutboundMessageRequest {
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
        let conversationObjectID: NSManagedObjectID
        let replyingToMessageObjectID: NSManagedObjectID?
        let body: String
        let attachments: [Attachment]
    }
}

struct OutboundMessageResult {
    let optimisticMessageID: String
    let conversationObjectID: NSManagedObjectID?
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
        attachments: [Attachment],
        existingConversationObjectID: NSManagedObjectID?
    ) async throws -> Message

    func attachmentToInfo(_ attachment: Attachment) -> GmailSendService.AttachmentInfo
    func attachmentSnapshot(_ attachment: Attachment) -> GmailSendService.AttachmentInfo
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
        let attachments: [Attachment]
        let inlineAttachments: [Attachment]
        let existingConversationObjectID: NSManagedObjectID?
        let replyData: ComposeSendOrchestrator.SendInput.ReplyData?
    }

    private let viewContext: NSManagedObjectContext
    private let sendService: any OutboundMessageSendServicing
    private let syncPerformer: IncrementalSyncPerforming
    private let replyMetadataBuilder: ReplyMetadataBuilder
    private let messageFormatBuilder: MessageFormatBuilder
    private let mutationTracker: any OutboundSendMutationTracking
    private var backgroundSendTasks: [String: Task<Void, Never>] = [:]

    init(
        viewContext: NSManagedObjectContext,
        sendService: any OutboundMessageSendServicing,
        syncPerformer: IncrementalSyncPerforming,
        replyMetadataBuilder: ReplyMetadataBuilder,
        messageFormatBuilder: MessageFormatBuilder,
        mutationTracker: any OutboundSendMutationTracking
    ) {
        self.viewContext = viewContext
        self.sendService = sendService
        self.syncPerformer = syncPerformer
        self.replyMetadataBuilder = replyMetadataBuilder
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
            existingConversationObjectID: preparedSend.existingConversationObjectID
        )
        let optimisticMessageID = optimisticMessage.id
        mutationTracker.trackPendingMutation(
            .init(
                optimisticMessageID: optimisticMessageID,
                conversationObjectID: optimisticMessage.conversation?.objectID
            )
        )

        let sendInput = ComposeSendOrchestrator.SendInput(
            recipientEmails: preparedSend.recipientEmails,
            body: preparedSend.body,
            htmlBody: preparedSend.htmlBody,
            subject: preparedSend.subject,
            attachmentInfos: preparedSend.attachments.map { sendService.attachmentToInfo($0) },
            inlineAttachmentInfos: preparedSend.inlineAttachments.map { sendService.attachmentSnapshot($0) },
            replyData: preparedSend.replyData
        )

        let effectiveHooks = makeReconciliationHooks(reconciliationHooks)
        let backgroundTask = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: syncPerformer
        ).executeInBackground(
            input: sendInput,
            attachmentObjectIDs: preparedSend.attachments.map(\.objectID),
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
            conversationObjectID: optimisticMessage.conversation?.objectID
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
                inlineAttachments: [],
                existingConversationObjectID: nil,
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
                existingConversationObjectID: nil,
                replyData: nil
            )

        case .reply(let reply):
            guard let conversation = fetchConversation(objectID: reply.conversationObjectID) else {
                throw GmailSendService.SendError.conversationNotFound
            }

            let replyConversation = ReplyMetadataBuilder.ConversationContext(
                participantEmails: Array(conversation.participants ?? [])
                    .compactMap { $0.person?.email },
                latestThreadId: Array(conversation.messages ?? [])
                    .sorted { $0.internalDate > $1.internalDate }
                    .first?
                    .gmThreadId
            )
            let replyTarget = reply.replyingToMessageObjectID.flatMap(makeReplyTargetContext)
            let body = normalizedBody(reply.body)
            let replyData = replyMetadataBuilder.buildReplyData(
                conversation: replyConversation,
                replyingTo: replyTarget,
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
                existingConversationObjectID: reply.conversationObjectID,
                replyData: ComposeSendOrchestrator.SendInput.ReplyData(replyData)
            )
        }
    }

    private func fetchConversation(objectID: NSManagedObjectID) -> Conversation? {
        do {
            return try viewContext.existingObject(with: objectID) as? Conversation
        } catch {
            Log.error("Failed to fetch conversation for outbound send", category: .coreData, error: error)
            return nil
        }
    }

    private func makeReplyTargetContext(objectID: NSManagedObjectID) -> ReplyMetadataBuilder.ReplyTargetContext? {
        let replyingTo: Message
        do {
            guard let message = try viewContext.existingObject(with: objectID) as? Message else {
                return nil
            }
            replyingTo = message
        } catch {
            Log.error("Failed to fetch reply target for outbound send", category: .coreData, error: error)
            return nil
        }

        let references = replyingTo.referencesValue?
            .split(separator: " ")
            .map(String.init) ?? []

        return ReplyMetadataBuilder.ReplyTargetContext(
            subject: replyingTo.subject,
            threadId: replyingTo.gmThreadId,
            messageId: replyingTo.messageIdValue,
            references: references,
            originalMessage: QuotedMessage(
                senderName: replyingTo.senderNameValue,
                senderEmail: replyingTo.senderEmailValue ?? "",
                date: replyingTo.internalDate,
                body: replyingTo.bodyTextValue
            )
        )
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
