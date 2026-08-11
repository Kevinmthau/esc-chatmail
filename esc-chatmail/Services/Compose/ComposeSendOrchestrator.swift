import Foundation
import CoreData

@MainActor
protocol IncrementalSyncPerforming: AnyObject {
    func performIncrementalSync() async throws
}

extension ForegroundSyncCoordinator: IncrementalSyncPerforming {}

protocol ComposeSendServicing: AnyObject {
    @MainActor func markAttachmentsAsUploaded(references: [LocalAttachmentReference])
    func sendReply(
        to recipients: [String],
        fromEmail: String?,
        fromName: String?,
        body: String,
        subject: String,
        threadId: String,
        inReplyTo: String?,
        references: [String],
        originalMessage: QuotedMessage?,
        attachmentInfos: [GmailSendService.AttachmentInfo],
        messageId: String?,
        beforeTransmission: @Sendable () async throws -> Void
    ) async throws -> GmailSendService.SendResult
    func sendNew(
        to recipients: [String],
        body: String,
        htmlBody: String?,
        subject: String?,
        attachmentInfos: [GmailSendService.AttachmentInfo],
        inlineAttachmentInfos: [GmailSendService.AttachmentInfo],
        messageId: String?,
        beforeTransmission: @Sendable () async throws -> Void
    ) async throws -> GmailSendService.SendResult
    @MainActor func remoteCommittedSendResult(optimisticMessageID: String) -> GmailSendService.SendResult?
    @MainActor func persistOptimisticMessageBeforeTransmission(optimisticMessageID: String) throws
    @MainActor func recordRemoteSendAdmission(optimisticMessageID: String) throws
    @MainActor func recordAmbiguousRemoteSend(optimisticMessageID: String) throws
    @MainActor func recordRemoteCommittedSend(
        optimisticMessageID: String,
        result: GmailSendService.SendResult
    ) throws
    @MainActor func reconcileRemoteCommittedSend(
        optimisticMessageID: String,
        result: GmailSendService.SendResult
    ) throws -> Bool
    @MainActor func rollbackOptimisticMessageBeforeTransmission(
        byID messageID: String,
        fallbackAttachmentReferences: [LocalAttachmentReference]
    )
    @MainActor func retainDefinitelyUnsentOptimisticMessage(
        byID messageID: String,
        fallbackAttachmentReferences: [LocalAttachmentReference]
    )
}

extension GmailSendService: ComposeSendServicing {}

private actor ComposeSendTransmissionAdmission {
    private var result: Result<Void, Error>?
    private var waiters: [CheckedContinuation<Result<Void, Error>, Never>] = []

    func wait() async throws {
        let result: Result<Void, Error>
        if let completed = self.result {
            result = completed
        } else {
            result = await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        try result.get()
    }

    func succeed() {
        resolve(.success(()))
    }

    func fail(_ error: Error) {
        resolve(.failure(error))
    }

    private func resolve(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume(returning: result) }
    }
}

/// Relays account-transition cancellation to the unstructured Gmail worker.
/// Cancellation can arrive after handoff but before that worker is installed.
private final class ComposeSendCancellationRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationRequested = false
    private var transmissionAdmitted = false
    private var cancelWorker: (@Sendable () -> Void)?

    func install<Success>(_ task: Task<Success, Error>) {
        let shouldCancel = lock.withLock {
            guard !transmissionAdmitted else { return false }
            cancelWorker = { task.cancel() }
            return cancellationRequested
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func cancelBeforeTransmission() {
        let cancelWorker = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !transmissionAdmitted else { return nil }
            cancellationRequested = true
            return self.cancelWorker
        }
        cancelWorker?()
    }

    func markTransmissionAdmitted() {
        lock.withLock {
            transmissionAdmitted = true
            cancelWorker = nil
        }
    }

    func workerFinished() {
        lock.withLock {
            cancelWorker = nil
        }
    }
}

struct ComposeSendBackgroundOperation {
    let task: Task<Void, Never>
    let cancelBeforeTransmission: @Sendable () -> Void
    private let admission: ComposeSendTransmissionAdmission

    fileprivate init(
        task: Task<Void, Never>,
        cancelBeforeTransmission: @escaping @Sendable () -> Void,
        admission: ComposeSendTransmissionAdmission
    ) {
        self.task = task
        self.cancelBeforeTransmission = cancelBeforeTransmission
        self.admission = admission
    }

    func waitForTransmissionAdmission() async throws {
        try await admission.wait()
    }
}

/// Orchestrates the message sending flow, handling optimistic updates and background execution
struct ComposeSendOrchestrator {
    let sendService: ComposeSendServicing
    let syncPerformer: IncrementalSyncPerforming

    private actor TransmissionBarrierState {
        private(set) var isPersisted = false

        func markPersisted() {
            isPersisted = true
        }
    }

    /// Input data for sending a message
    struct SendInput: Sendable {
        let recipientEmails: [String]
        let body: String
        let htmlBody: String?
        let subject: String?
        let attachmentInfos: [GmailSendService.AttachmentInfo]
        let inlineAttachmentInfos: [GmailSendService.AttachmentInfo]
        let replyMetadata: OutboundMessageRequest.ReplyMetadata?
    }

    /// Creates an optimistic message and triggers background send
    /// - Parameters:
    ///   - input: The send input data
    ///   - attachmentReferences: Attachment references for post-send state updates
    ///   - optimisticMessageID: ID of the pre-created optimistic message
    @MainActor
    @discardableResult
    func executeInBackground(
        input: SendInput,
        attachmentReferences: [LocalAttachmentReference],
        optimisticMessageID: String,
        reconciliationHooks: OutboundMessageReconciliationHooks = .none,
        transmissionAdmission: (@MainActor @Sendable () throws -> Void)? = nil
    ) -> ComposeSendBackgroundOperation {
        // Capture services for background task
        let sendService = self.sendService
        let syncPerformer = self.syncPerformer
        let admission = ComposeSendTransmissionAdmission()
        let cancellationRelay = ComposeSendCancellationRelay()

        // Send in background - don't wait for completion
        let task = Task.detached(priority: .userInitiated) {
            let transmissionBarrierState = TransmissionBarrierState()
            do {
                let result: GmailSendService.SendResult
                if let committedResult = await MainActor.run(body: {
                    sendService.remoteCommittedSendResult(optimisticMessageID: optimisticMessageID)
                }) {
                    result = committedResult
                    Log.info(
                        "Skipping Gmail send for already committed optimistic message \(optimisticMessageID)",
                        category: .message
                    )
                    await admission.succeed()
                } else {
                    // Keep the optimistic graph durable throughout attachment and
                    // MIME preflight without claiming Gmail may have received it.
                    // The caller still owns the source composer until the later
                    // admission handshake succeeds.
                    try await MainActor.run {
                        try sendService.persistOptimisticMessageBeforeTransmission(
                            optimisticMessageID: optimisticMessageID
                        )
                    }

                    let sendTask = Task.detached(priority: .userInitiated) {
                        let result: GmailSendService.SendResult

                        let beforeTransmission: @Sendable () async throws -> Void = {
                            // GmailSendService invokes this only after attachment
                            // loading and MIME construction, immediately before the
                            // non-idempotent API request. A failed marker save must
                            // therefore prevent request admission.
                            try await MainActor.run {
                                if let transmissionAdmission {
                                    try transmissionAdmission()
                                } else {
                                    try sendService.recordRemoteSendAdmission(
                                        optimisticMessageID: optimisticMessageID
                                    )
                                }
                            }
                            cancellationRelay.markTransmissionAdmitted()
                            await transmissionBarrierState.markPersisted()
                            await admission.succeed()
                        }

                        if let replyMetadata = input.replyMetadata,
                           let threadId = replyMetadata.threadId,
                           !threadId.isEmpty {
                            result = try await sendService.sendReply(
                                to: replyMetadata.recipientEmails,
                                fromEmail: replyMetadata.fromEmail,
                                fromName: replyMetadata.fromName,
                                body: input.body,
                                subject: replyMetadata.subject ?? "",
                                threadId: threadId,
                                inReplyTo: replyMetadata.inReplyTo,
                                references: replyMetadata.references,
                                originalMessage: replyMetadata.originalMessage,
                                attachmentInfos: input.attachmentInfos,
                                messageId: MimeBuilder.messageId(
                                    forOptimisticMessageID: optimisticMessageID
                                ),
                                beforeTransmission: beforeTransmission
                            )
                        } else {
                            result = try await sendService.sendNew(
                                to: input.recipientEmails,
                                body: input.body,
                                htmlBody: input.htmlBody,
                                subject: input.subject,
                                attachmentInfos: input.attachmentInfos,
                                inlineAttachmentInfos: input.inlineAttachmentInfos,
                                messageId: MimeBuilder.messageId(
                                    forOptimisticMessageID: optimisticMessageID
                                ),
                                beforeTransmission: beforeTransmission
                            )
                        }

                        return result
                    }
                    cancellationRelay.install(sendTask)
                    defer { cancellationRelay.workerFinished() }
                    result = try await sendTask.value

                    do {
                        try await MainActor.run {
                            try sendService.recordRemoteCommittedSend(
                                optimisticMessageID: optimisticMessageID,
                                result: result
                            )
                        }
                    } catch {
                        Log.error(
                            "Remote send succeeded but failed to persist commit for optimistic message \(optimisticMessageID)",
                            category: .message,
                            error: error
                        )
                    }
                }

                // Reflect the committed result locally; exact sync owns the
                // atomic optimistic-row replacement and mutation consumption.
                await MainActor.run {
                    do {
                        _ = try sendService.reconcileRemoteCommittedSend(
                            optimisticMessageID: optimisticMessageID,
                            result: result
                        )
                    } catch {
                        Log.error(
                            "Remote send succeeded but local reconciliation failed for optimistic message \(optimisticMessageID)",
                            category: .message,
                            error: error
                        )
                    }
                    sendService.markAttachmentsAsUploaded(references: attachmentReferences)
                    reconciliationHooks.onSuccess?(
                        .init(
                            optimisticMessageID: optimisticMessageID,
                            sentMessageID: result.messageId,
                            threadID: result.threadId
                        )
                    )
                }

                if Task.isCancelled {
                    Log.info("Background send completed after cancellation for optimistic message \(optimisticMessageID)", category: .message)
                    return
                }

                // Trigger sync to fetch the sent message from Gmail
                // Sync failure is non-critical - message was sent successfully, user will
                // see it on next sync. Log warning for debugging but don't surface to user.
                do {
                    try await syncPerformer.performIncrementalSync()
                } catch {
                    Log.warning("Post-send sync failed - sent message will appear on next sync: \(error.localizedDescription)", category: .sync)
                }
            } catch let error as GmailSendService.SendError where error.isAmbiguousDelivery {
                if await transmissionBarrierState.isPersisted {
                    await handleAmbiguousOutcome(
                        sendService: sendService,
                        attachmentReferences: attachmentReferences,
                        optimisticMessageID: optimisticMessageID,
                        reconciliationHooks: reconciliationHooks
                    )
                    await admission.succeed()
                    Log.info("Background send outcome was ambiguous for optimistic message \(optimisticMessageID)", category: .message)
                } else {
                    await handleDefiniteFailure(
                        sendService: sendService,
                        attachmentReferences: attachmentReferences,
                        optimisticMessageID: optimisticMessageID,
                        reconciliationHooks: reconciliationHooks,
                        error: error
                    )
                    await admission.fail(error)
                }
            } catch is CancellationError {
                if await transmissionBarrierState.isPersisted {
                    // Cancellation after the durable barrier is ambiguous: Gmail
                    // may have committed the non-idempotent send. Keep the marker
                    // and optimistic state; never offer a duplicate retry.
                    await handleAmbiguousOutcome(
                        sendService: sendService,
                        attachmentReferences: attachmentReferences,
                        optimisticMessageID: optimisticMessageID,
                        reconciliationHooks: reconciliationHooks
                    )
                    await admission.succeed()
                    Log.info("Background send outcome was ambiguous for optimistic message \(optimisticMessageID)", category: .message)
                } else {
                    await handleDefiniteFailure(
                        sendService: sendService,
                        attachmentReferences: attachmentReferences,
                        optimisticMessageID: optimisticMessageID,
                        reconciliationHooks: reconciliationHooks,
                        error: CancellationError()
                    )
                    await admission.fail(CancellationError())
                }
            } catch {
                if await transmissionBarrierState.isPersisted {
                    // Gmail returned a definite rejection after request admission.
                    // The source composer has already handed off its contents, so
                    // retain the durable optimistic graph as an explicit failure.
                    await handleRetainedDefiniteFailure(
                        sendService: sendService,
                        attachmentReferences: attachmentReferences,
                        optimisticMessageID: optimisticMessageID,
                        reconciliationHooks: reconciliationHooks,
                        error: error
                    )
                    await admission.succeed()
                } else {
                    await handleDefiniteFailure(
                        sendService: sendService,
                        attachmentReferences: attachmentReferences,
                        optimisticMessageID: optimisticMessageID,
                        reconciliationHooks: reconciliationHooks,
                        error: error
                    )
                    await admission.fail(error)
                }
            }
        }
        return ComposeSendBackgroundOperation(
            task: task,
            cancelBeforeTransmission: {
                cancellationRelay.cancelBeforeTransmission()
            },
            admission: admission
        )
    }

    private func handleAmbiguousOutcome(
        sendService: ComposeSendServicing,
        attachmentReferences: [LocalAttachmentReference],
        optimisticMessageID: String,
        reconciliationHooks: OutboundMessageReconciliationHooks
    ) async {
        await MainActor.run {
            do {
                try sendService.recordAmbiguousRemoteSend(
                    optimisticMessageID: optimisticMessageID
                )
            } catch {
                // The durable admission marker still prevents a duplicate retry;
                // cold recovery will conservatively convert it to unknown.
                Log.error(
                    "Failed to persist delivery-unknown state for \(optimisticMessageID)",
                    category: .message,
                    error: error
                )
            }
            sendService.markAttachmentsAsUploaded(references: attachmentReferences)
            reconciliationHooks.onAmbiguous?(
                .init(optimisticMessageID: optimisticMessageID)
            )
        }
    }

    private func handleDefiniteFailure(
        sendService: ComposeSendServicing,
        attachmentReferences: [LocalAttachmentReference],
        optimisticMessageID: String,
        reconciliationHooks: OutboundMessageReconciliationHooks,
        error: Error
    ) async {
        await MainActor.run {
            sendService.rollbackOptimisticMessageBeforeTransmission(
                byID: optimisticMessageID,
                fallbackAttachmentReferences: attachmentReferences
            )
            reconciliationHooks.onFailure?(
                .init(
                    optimisticMessageID: optimisticMessageID,
                    errorDescription: error.localizedDescription
                )
            )
        }
        Log.error("Background send failed", category: .message, error: error)
    }

    private func handleRetainedDefiniteFailure(
        sendService: ComposeSendServicing,
        attachmentReferences: [LocalAttachmentReference],
        optimisticMessageID: String,
        reconciliationHooks: OutboundMessageReconciliationHooks,
        error: Error
    ) async {
        await MainActor.run {
            sendService.retainDefinitelyUnsentOptimisticMessage(
                byID: optimisticMessageID,
                fallbackAttachmentReferences: attachmentReferences
            )
            reconciliationHooks.onFailure?(
                .init(
                    optimisticMessageID: optimisticMessageID,
                    errorDescription: error.localizedDescription
                )
            )
        }
        Log.error("Background send was definitely rejected", category: .message, error: error)
    }
}

private extension GmailSendService.SendError {
    var isAmbiguousDelivery: Bool {
        if case .ambiguousDelivery = self { return true }
        return false
    }
}
