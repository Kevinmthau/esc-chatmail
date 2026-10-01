import Foundation
import CoreData

enum OutboundMessageRequest {
    case compose(Compose)
    case forward(Forward)
    case reply(Reply)

    struct AttachmentContext {
        let info: GmailSendService.AttachmentInfo
        let localAttachmentReference: LocalAttachmentReference
    }

    struct ReplyMetadata: Sendable {
        let recipientEmails: [String]
        let fromEmail: String
        let fromName: String?
        let subject: String?
        let threadId: String?
        let inReplyTo: String?
        let references: [String]
        let originalMessage: QuotedMessage?
    }

    struct ReplyContext {
        let conversationObjectID: NSManagedObjectID
        let replyingToMessageObjectID: NSManagedObjectID?
        let optimisticConversation: OptimisticConversationReference?
        let includesQuotedMessage: Bool

        init(
            conversationObjectID: NSManagedObjectID,
            replyingToMessageObjectID: NSManagedObjectID?,
            optimisticConversation: OptimisticConversationReference?,
            includesQuotedMessage: Bool = true
        ) {
            self.conversationObjectID = conversationObjectID
            self.replyingToMessageObjectID = replyingToMessageObjectID
            self.optimisticConversation = optimisticConversation
            self.includesQuotedMessage = includesQuotedMessage
        }
    }

    struct Compose {
        let recipientEmails: [String]
        let subject: String?
        let body: String
        let attachments: [AttachmentContext]
        let optimisticConversation: OptimisticConversationReference?

        init(
            recipientEmails: [String],
            subject: String?,
            body: String,
            attachments: [AttachmentContext],
            optimisticConversation: OptimisticConversationReference? = nil
        ) {
            self.recipientEmails = recipientEmails
            self.subject = subject
            self.body = body
            self.attachments = attachments
            self.optimisticConversation = optimisticConversation
        }
    }

    struct Forward {
        let recipientEmails: [String]
        let subject: String?
        let body: String
        let attachments: [AttachmentContext]
        let forwardedPlainTextBody: String
        let forwardedHTMLBody: String?
        let forwardedInlineAttachmentInfos: [GmailSendService.AttachmentInfo]
        let optimisticConversation: OptimisticConversationReference?

        init(
            recipientEmails: [String],
            subject: String?,
            body: String,
            attachments: [AttachmentContext],
            forwardedPlainTextBody: String,
            forwardedHTMLBody: String?,
            forwardedInlineAttachmentInfos: [GmailSendService.AttachmentInfo],
            optimisticConversation: OptimisticConversationReference? = nil
        ) {
            self.recipientEmails = recipientEmails
            self.subject = subject
            self.body = body
            self.attachments = attachments
            self.forwardedPlainTextBody = forwardedPlainTextBody
            self.forwardedHTMLBody = forwardedHTMLBody
            self.forwardedInlineAttachmentInfos = forwardedInlineAttachmentInfos
            self.optimisticConversation = optimisticConversation
        }
    }

    struct Reply {
        let context: ReplyContext
        let body: String
        let attachments: [AttachmentContext]
        let retryMetadata: ReplyMetadata?
        /// Chat replies pass `.retainAsNotSent`: their composer releases at
        /// optimistic persistence, so a rollback has no composer to return to.
        let preTransmissionFailureDisposition: PreTransmissionFailureDisposition

        init(
            context: ReplyContext,
            body: String,
            attachments: [AttachmentContext],
            retryMetadata: ReplyMetadata? = nil,
            preTransmissionFailureDisposition: PreTransmissionFailureDisposition = .rollBackToComposer
        ) {
            self.context = context
            self.body = body
            self.attachments = attachments
            self.retryMetadata = retryMetadata
            self.preTransmissionFailureDisposition = preTransmissionFailureDisposition
        }
    }

    /// Compose and forward always roll back: ComposeView keeps its content
    /// (and its spinner) until transmission admission.
    var preTransmissionFailureDisposition: PreTransmissionFailureDisposition {
        switch self {
        case .compose, .forward:
            return .rollBackToComposer
        case .reply(let reply):
            return reply.preTransmissionFailureDisposition
        }
    }
}

struct OutboundMessageResult {
    let optimisticMessageID: String
    let optimisticMessageObjectID: NSManagedObjectID
    let conversationReference: ConversationReference?
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

    struct Ambiguous: Sendable {
        let optimisticMessageID: String
    }

    let onSuccess: (@Sendable @MainActor (Success) -> Void)?
    let onFailure: (@Sendable @MainActor (Failure) -> Void)?
    let onAmbiguous: (@Sendable @MainActor (Ambiguous) -> Void)?

    init(
        onSuccess: (@Sendable @MainActor (Success) -> Void)?,
        onFailure: (@Sendable @MainActor (Failure) -> Void)?,
        onAmbiguous: (@Sendable @MainActor (Ambiguous) -> Void)? = nil
    ) {
        self.onSuccess = onSuccess
        self.onFailure = onFailure
        self.onAmbiguous = onAmbiguous
    }

    static let none = Self(onSuccess: nil, onFailure: nil, onAmbiguous: nil)
}

@MainActor
protocol OutboundMessageCoordinating: AnyObject {
    func checkDelivery() async throws
    /// Reports the persisted optimistic identity before awaiting local preflight,
    /// then returns only after durable transmission admission, or once a
    /// pre-barrier failure of a `.retainAsNotSent` request has been retained
    /// as "Not sent".
    ///
    /// A throw after `onOptimisticMessagePersisted` means the optimistic graph
    /// was rolled back (a `.rollBackToComposer` failure, or any pre-barrier
    /// cancellation, including account teardown), so the caller is again the
    /// only owner of the content it snapshotted.
    func send(
        preparing requestBuilder: @escaping @MainActor () async throws -> OutboundMessageRequest,
        reconciliationHooks: OutboundMessageReconciliationHooks,
        onOptimisticMessagePersisted: (@MainActor (OutboundMessageResult) -> Void)?
    ) async throws -> OutboundMessageResult?
}

extension OutboundMessageCoordinating {
    func checkDelivery() async throws {}

    func send(
        _ request: OutboundMessageRequest,
        reconciliationHooks: OutboundMessageReconciliationHooks
    ) async throws -> OutboundMessageResult? {
        try await send(
            preparing: { request },
            reconciliationHooks: reconciliationHooks,
            onOptimisticMessagePersisted: nil
        )
    }

    func send(
        _ request: OutboundMessageRequest,
        onOptimisticMessagePersisted: @escaping @MainActor (OutboundMessageResult) -> Void
    ) async throws -> OutboundMessageResult? {
        try await send(
            preparing: { request },
            reconciliationHooks: .none,
            onOptimisticMessagePersisted: onOptimisticMessagePersisted
        )
    }

    func send(_ request: OutboundMessageRequest) async throws -> OutboundMessageResult? {
        try await send(request, reconciliationHooks: .none)
    }

    func send(
        preparing requestBuilder: @escaping @MainActor () async throws -> OutboundMessageRequest
    ) async throws -> OutboundMessageResult? {
        try await send(
            preparing: requestBuilder,
            reconciliationHooks: .none,
            onOptimisticMessagePersisted: nil
        )
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
        chatPreviewText: String?,
        senderEmail: String?,
        senderName: String?,
        optimisticConversation: OptimisticConversationReference?,
        replyMetadata: OutboundMessageRequest.ReplyMetadata?
    ) async throws -> OptimisticSendHandle

    @MainActor
    func markAttachmentsAsUploading(
        references: [LocalAttachmentReference]
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
        let chatPreviewText: String?
        let inlineAttachmentInfos: [GmailSendService.AttachmentInfo]
        let optimisticConversation: OptimisticConversationReference?
        let replyMetadata: OutboundMessageRequest.ReplyMetadata?
        let preTransmissionFailureDisposition: PreTransmissionFailureDisposition
    }

    private struct OptimisticPreparation {
        let preparedSend: PreparedSend
        let handle: OptimisticSendHandle
    }

    private let sendService: any OutboundMessageSendServicing
    private let syncPerformer: IncrementalSyncPerforming
    private let messageFormatBuilder: MessageFormatBuilder
    private let outboundReplyContextBuilder: OutboundReplyContextBuilder
    private let mutationTracker: any OutboundSendMutationTracking
    private let outboundTaskRegistry: OutboundTaskRegistry
    private let sendSequencer: OutboundConversationSendSequencer

    init(
        sendService: any OutboundMessageSendServicing,
        syncPerformer: IncrementalSyncPerforming,
        messageFormatBuilder: MessageFormatBuilder,
        outboundReplyContextBuilder: OutboundReplyContextBuilder,
        mutationTracker: any OutboundSendMutationTracking,
        outboundTaskRegistry: OutboundTaskRegistry? = nil,
        sendSequencer: OutboundConversationSendSequencer? = nil
    ) {
        self.sendService = sendService
        self.syncPerformer = syncPerformer
        self.messageFormatBuilder = messageFormatBuilder
        self.outboundReplyContextBuilder = outboundReplyContextBuilder
        self.mutationTracker = mutationTracker
        self.outboundTaskRegistry = outboundTaskRegistry ?? .shared
        self.sendSequencer = sendSequencer ?? .shared
    }

    func send(
        preparing requestBuilder: @escaping @MainActor () async throws -> OutboundMessageRequest,
        reconciliationHooks: OutboundMessageReconciliationHooks = .none,
        onOptimisticMessagePersisted: (@MainActor (OutboundMessageResult) -> Void)? = nil
    ) async throws -> OutboundMessageResult? {
        // Reserve before the first suspension point. Account teardown can then
        // close admission and await this preparation even if optimistic state
        // has not yet been created or the background task has not been handed off.
        guard let reservation = outboundTaskRegistry.reserve() else {
            throw CancellationError()
        }
        var didHandOffReservation = false
        defer {
            if !didHandOffReservation {
                outboundTaskRegistry.finish(reservation)
            }
        }

        let preparationTask: Task<OptimisticPreparation, Error> = Task { @MainActor in
            let request = try await requestBuilder()
            let preparedSend = try await prepare(request)
            try checkActive(reservation)
            guard !preparedSend.recipientEmails.isEmpty else {
                throw GmailSendService.SendError.noRecipients
            }
            // Refuse a threadless reply before the optimistic row exists. The
            // background worker refuses it too (`replyTargetUnavailable`), but
            // that is pre-barrier, where a chat reply is retained as "Not
            // sent": Edit and resend would rebuild the same threadless
            // envelope and fail the same way. Refused here, the composer keeps
            // the text and shows why.
            if let replyMetadata = preparedSend.replyMetadata {
                guard let threadId = replyMetadata.threadId?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !threadId.isEmpty else {
                    throw GmailSendService.SendError.replyTargetUnavailable
                }
            }

            let handle = try await sendService.createOptimisticMessage(
                to: preparedSend.recipientEmails,
                body: preparedSend.body,
                subject: preparedSend.subject,
                threadId: preparedSend.threadId,
                attachments: preparedSend.attachments,
                chatPreviewText: preparedSend.chatPreviewText,
                senderEmail: preparedSend.replyMetadata?.fromEmail,
                senderName: preparedSend.replyMetadata?.fromName,
                optimisticConversation: preparedSend.optimisticConversation,
                replyMetadata: preparedSend.replyMetadata
            )
            do {
                try checkActive(reservation)
            } catch {
                sendService.rollbackOptimisticMessageBeforeTransmission(
                    byID: handle.optimisticMessageID,
                    fallbackAttachmentReferences: preparedSend.attachments.map(\.localAttachmentReference)
                )
                reconciliationHooks.onFailure?(
                    .init(
                        optimisticMessageID: handle.optimisticMessageID,
                        errorDescription: error.localizedDescription
                    )
                )
                throw error
            }
            return OptimisticPreparation(preparedSend: preparedSend, handle: handle)
        }
        guard outboundTaskRegistry.ownPreparation(preparationTask, for: reservation) else {
            throw CancellationError()
        }
        let preparation = try await withTaskCancellationHandler {
            try await preparationTask.value
        } onCancel: {
            preparationTask.cancel()
        }
        let preparedSend = preparation.preparedSend
        let optimisticSendHandle = preparation.handle
        let optimisticMessageID = optimisticSendHandle.optimisticMessageID
        do {
            // MainActor serialization makes the following background-task
            // creation + registry handoff atomic with admission closure. MIME
            // and attachment preflight remain cancellable after this point.
            try checkActive(reservation)
        } catch {
            sendService.rollbackOptimisticMessageBeforeTransmission(
                byID: optimisticMessageID,
                fallbackAttachmentReferences: preparedSend.attachments.map(\.localAttachmentReference)
            )
            reconciliationHooks.onFailure?(
                .init(
                    optimisticMessageID: optimisticMessageID,
                    errorDescription: error.localizedDescription
                )
            )
            throw error
        }

        mutationTracker.trackPendingMutation(
            .init(
                optimisticMessageID: optimisticMessageID,
                conversationReference: optimisticSendHandle.conversationReference
            )
        )
        if !preparedSend.attachments.isEmpty {
            sendService.markAttachmentsAsUploading(
                references: preparedSend.attachments.map(\.localAttachmentReference)
            )
        }

        let optimisticResult = OutboundMessageResult(
            optimisticMessageID: optimisticMessageID,
            optimisticMessageObjectID: optimisticSendHandle.optimisticMessageObjectID,
            conversationReference: optimisticSendHandle.conversationReference
        )
        let sendInput = ComposeSendOrchestrator.SendInput(
            recipientEmails: preparedSend.recipientEmails,
            body: preparedSend.body,
            htmlBody: preparedSend.htmlBody,
            subject: preparedSend.subject,
            attachmentInfos: preparedSend.attachments.map(\.info),
            inlineAttachmentInfos: preparedSend.inlineAttachmentInfos,
            replyMetadata: preparedSend.replyMetadata
        )

        let effectiveHooks = makeReconciliationHooks(reconciliationHooks)
        // Enqueued on the main actor right after the optimistic row was
        // created, so queue order is bubble order. The background operation
        // finishes the turn on every path.
        let sendOrderTurn = optimisticSendHandle.conversationReference.map {
            sendSequencer.enqueue(conversation: $0)
        }
        let backgroundOperation = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: syncPerformer
        ).executeInBackground(
            input: sendInput,
            attachmentReferences: preparedSend.attachments.map(\.localAttachmentReference),
            optimisticMessageID: optimisticMessageID,
            reconciliationHooks: effectiveHooks,
            preTransmissionFailureDisposition: preparedSend.preTransmissionFailureDisposition,
            sendOrderTurn: sendOrderTurn,
            transmissionAdmission: { [sendService, outboundTaskRegistry] in
                try outboundTaskRegistry.admitTransmission(
                    reservation,
                    persistingMarker: {
                        try sendService.recordRemoteSendAdmission(
                            optimisticMessageID: optimisticMessageID
                        )
                    }
                )
            }
        )

        // The registry cancels the inner worker during preflight, then retains
        // this outer task as the drain owner once Gmail admission is durable.
        let remainsActive = outboundTaskRegistry.handOff(
            reservation,
            to: backgroundOperation.task,
            cancelBeforeTransmission: backgroundOperation.cancelBeforeTransmission
        )
        didHandOffReservation = true
        guard remainsActive else {
            throw CancellationError()
        }

        // The optimistic graph and recovery record are durable, and the
        // registry now owns preflight cleanup. Publish the stable identity
        // before yielding for transmission admission so chat can materialize
        // and anchor the exact row while MIME work continues.
        onOptimisticMessagePersisted?(optimisticResult)

        // A `.rollBackToComposer` caller (ComposeView) clears its composer
        // only after all local preflight has completed and the optimistic
        // graph + ambiguity marker are durable at final Gmail request
        // admission; failures before admission propagate while that composer
        // still owns the user's content. A `.retainAsNotSent` caller (the chat
        // reply bar) has already released its composer at the callback above;
        // its send-path failures resolve admission here as a retained "Not
        // sent" row instead of throwing.
        try await backgroundOperation.waitForTransmissionAdmission()

        return optimisticResult
    }

    func checkDelivery() async throws {
        try await syncPerformer.performIncrementalSync()
    }

    private func checkActive(_ reservation: OutboundSendReservation) throws {
        try Task.checkCancellation()
        guard outboundTaskRegistry.isActive(reservation) else {
            throw CancellationError()
        }
    }

    private func prepare(_ request: OutboundMessageRequest) async throws -> PreparedSend {
        switch request {
        case .compose(let compose):
            let body = normalizedBody(compose.body)
            return PreparedSend(
                recipientEmails: compose.recipientEmails,
                body: body,
                subject: normalizedSubject(compose.subject),
                htmlBody: nil,
                threadId: nil,
                attachments: compose.attachments,
                chatPreviewText: optimisticChatPreviewText(from: body),
                inlineAttachmentInfos: [],
                optimisticConversation: compose.optimisticConversation,
                replyMetadata: nil,
                preTransmissionFailureDisposition: request.preTransmissionFailureDisposition
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
                chatPreviewText: optimisticChatPreviewText(from: userBody),
                inlineAttachmentInfos: forward.forwardedInlineAttachmentInfos,
                optimisticConversation: forward.optimisticConversation,
                replyMetadata: nil,
                preTransmissionFailureDisposition: request.preTransmissionFailureDisposition
            )

        case .reply(let reply):
            let body = normalizedBody(reply.body)
            let metadata: OutboundMessageRequest.ReplyMetadata
            if let retryMetadata = reply.retryMetadata {
                try outboundReplyContextBuilder.validateRecoveredReply(retryMetadata, context: reply.context)
                metadata = retryMetadata
            } else {
                metadata = try await outboundReplyContextBuilder.buildReplyMetadata(reply.context)
            }

            return PreparedSend(
                recipientEmails: metadata.recipientEmails,
                body: body,
                subject: metadata.subject,
                htmlBody: nil,
                threadId: metadata.threadId,
                attachments: reply.attachments,
                chatPreviewText: optimisticChatPreviewText(from: body),
                inlineAttachmentInfos: [],
                optimisticConversation: reply.context.optimisticConversation,
                replyMetadata: metadata,
                preTransmissionFailureDisposition: request.preTransmissionFailureDisposition
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

    private func optimisticChatPreviewText(from text: String) -> String? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedText.isEmpty ? nil : trimmedText
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
            },
            onAmbiguous: { [weak mutationTracker] ambiguous in
                mutationTracker?.reconcileAmbiguous(ambiguous)
                externalHooks.onAmbiguous?(ambiguous)
            }
        )
    }
}
