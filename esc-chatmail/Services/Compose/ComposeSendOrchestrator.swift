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
    @MainActor func recordSendFailureReason(optimisticMessageID: String, reason: String)
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
    @MainActor @discardableResult func rollbackOptimisticMessageBeforeTransmission(
        byID messageID: String,
        fallbackAttachmentReferences: [LocalAttachmentReference]
    ) -> PreTransmissionRollbackOutcome
    @MainActor func retainDefinitelyUnsentOptimisticMessage(
        byID messageID: String,
        fallbackAttachmentReferences: [LocalAttachmentReference]
    )
}

extension ComposeSendServicing {
    @MainActor func recordSendFailureReason(optimisticMessageID: String, reason: String) {}
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
    private var backgroundTimeExpired = false
    private var transmissionAdmitted = false
    private var cancelWorker: (@Sendable () -> Void)?

    func install<Success>(_ task: Task<Success, Error>) {
        let shouldCancel = lock.withLock {
            cancelWorker = { task.cancel() }
            return backgroundTimeExpired || (cancellationRequested && !transmissionAdmitted)
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
        }
    }

    /// OS expiration must release execution time even for an admitted request.
    /// Its durable marker makes cancellation ambiguous instead of retryable.
    func expireBackgroundTime() {
        let cancelWorker = lock.withLock {
            backgroundTimeExpired = true
            return self.cancelWorker
        }
        cancelWorker?()
    }

    func checkBackgroundTime() throws {
        if lock.withLock({ backgroundTimeExpired }) {
            throw CancellationError()
        }
    }

    /// Account teardown or OS expiration asked this send to stop. Its
    /// pre-barrier failure can then surface as an arbitrary error (a token
    /// refresh cancelled mid-request, say), and must still roll back rather
    /// than leave a "Not sent" row in an account being torn down.
    var stopWasRequested: Bool {
        lock.withLock { cancellationRequested || backgroundTimeExpired }
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
    private let backgroundTaskManager: any OutboundBackgroundTaskManaging
    private let networkPathMonitor: any OutboundNetworkPathMonitoring
    /// Times only the pre-barrier connectivity wait's deadline.
    private let connectivityWaitClock: any SyncClock

    @MainActor
    init(
        sendService: ComposeSendServicing,
        syncPerformer: IncrementalSyncPerforming,
        backgroundTaskManager: (any OutboundBackgroundTaskManaging)? = nil,
        networkPathMonitor: (any OutboundNetworkPathMonitoring)? = nil,
        connectivityWaitClock: any SyncClock = SystemSyncClock()
    ) {
        self.sendService = sendService
        self.syncPerformer = syncPerformer
        self.backgroundTaskManager = backgroundTaskManager ?? UIKitOutboundBackgroundTaskManager()
        self.networkPathMonitor = networkPathMonitor ?? OutboundNetworkPathMonitor.shared
        self.connectivityWaitClock = connectivityWaitClock
    }

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
    ///   - preTransmissionFailureDisposition: What a non-cancellation send-path
    ///     failure before the barrier does. Cancellation and account teardown
    ///     roll back regardless.
    ///   - sendOrderTurn: This send's place in its conversation's FIFO. It is
    ///     awaited strictly before the transmission barrier and finished on
    ///     every path. nil for sends outside the FIFO (ComposeView compose and
    ///     forward; see `OutboundMessageRequest.takesConversationSendTurn`).
    @MainActor
    @discardableResult
    func executeInBackground(
        input: SendInput,
        attachmentReferences: [LocalAttachmentReference],
        optimisticMessageID: String,
        reconciliationHooks: OutboundMessageReconciliationHooks = .none,
        preTransmissionFailureDisposition: PreTransmissionFailureDisposition = .rollBackToComposer,
        sendOrderTurn: OutboundConversationSendSequencer.Turn? = nil,
        transmissionAdmission: (@MainActor @Sendable () throws -> Void)? = nil
    ) -> ComposeSendBackgroundOperation {
        // Capture services for background task
        let sendService = self.sendService
        let syncPerformer = self.syncPerformer
        let networkPathMonitor = self.networkPathMonitor
        let connectivityWaitClock = self.connectivityWaitClock
        let admission = ComposeSendTransmissionAdmission()
        let cancellationRelay = ComposeSendCancellationRelay()
        let backgroundLease = OutboundSendBackgroundLease(manager: backgroundTaskManager) {
            cancellationRelay.expireBackgroundTime()
        }

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
                    await sendOrderTurn?.finish()
                    await admission.succeed()
                } else {
                    // Keep the optimistic graph durable throughout attachment and
                    // MIME preflight without claiming Gmail may have received it.
                    // A `.rollBackToComposer` caller still owns the source
                    // composer until the later admission handshake succeeds.
                    try await MainActor.run {
                        try sendService.persistOptimisticMessageBeforeTransmission(
                            optimisticMessageID: optimisticMessageID
                        )
                    }

                    let transmit: @Sendable () async throws -> GmailSendService.SendResult = {
                        let result: GmailSendService.SendResult

                        // Bounded wait for a usable network path, strictly
                        // before the barrier and before the conversation turn:
                        // each queued send starts its own deadline when it
                        // starts, instead of serially behind its predecessor's
                        // wait. A deadline failure is a pre-transmission
                        // `-1009`, so the disposition below decides it like
                        // any other pre-barrier failure; cancellation rolls
                        // back. Never repeated after the barrier.
                        try await OutboundConnectivityGate.waitForUsablePath(
                            monitor: networkPathMonitor,
                            clock: connectivityWaitClock
                        )

                        let beforeTransmission: @Sendable () async throws -> Void = {
                            // GmailSendService invokes this only after attachment
                            // loading and MIME construction, immediately before the
                            // non-idempotent API request. A failed marker save must
                            // therefore prevent request admission.
                            try await MainActor.run {
                                try Task.checkCancellation()
                                try cancellationRelay.checkBackgroundTime()
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

                        if let replyMetadata = input.replyMetadata {
                            guard let threadId = replyMetadata.threadId?
                                .trimmingCharacters(in: .whitespacesAndNewlines),
                                  !threadId.isEmpty else {
                                throw GmailSendService.SendError.replyTargetUnavailable
                            }
                            let originalMessage: QuotedMessage?
                            if let deferredOriginalMessage = replyMetadata.originalMessage {
                                originalMessage = await deferredOriginalMessage.resolvingOriginalHTML()
                            } else {
                                originalMessage = nil
                            }
                            // Strictly before the barrier, and a cancelled wait
                            // is a definite pre-barrier failure. Only the
                            // connectivity wait and quoted-HTML resolution above
                            // overlap the previous send; attachment reads and
                            // MIME construction run inside `sendReply`, after
                            // this turn.
                            try await sendOrderTurn?.waitUntilFront()
                            result = try await sendService.sendReply(
                                to: replyMetadata.recipientEmails,
                                fromEmail: replyMetadata.fromEmail,
                                fromName: replyMetadata.fromName,
                                body: input.body,
                                subject: replyMetadata.subject ?? "",
                                threadId: threadId,
                                inReplyTo: replyMetadata.inReplyTo,
                                references: replyMetadata.references,
                                originalMessage: originalMessage,
                                attachmentInfos: input.attachmentInfos,
                                messageId: MimeBuilder.messageId(
                                    forOptimisticMessageID: optimisticMessageID
                                ),
                                beforeTransmission: beforeTransmission
                            )
                        } else {
                            try await sendOrderTurn?.waitUntilFront()
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
                    let sendTask = Task.detached(priority: .userInitiated) {
                        // Gmail has answered (or this send failed without
                        // reaching it): either way it is terminal, so the next
                        // send in the conversation may transmit. Release before
                        // local reconciliation and the optional sync.
                        do {
                            let result = try await transmit()
                            await sendOrderTurn?.finish()
                            return result
                        } catch {
                            await sendOrderTurn?.finish()
                            throw error
                        }
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
                    // Commit/reconciliation have finished; their durable recovery
                    // marker remains if saving failed. Optional mailbox sync must
                    // not extend the send's limited background allowance.
                    backgroundLease.end()
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
                        admission: admission,
                        error: error
                    )
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
                        admission: admission,
                        error: CancellationError()
                    )
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
                } else if preTransmissionFailureDisposition == .retainAsNotSent,
                          !cancellationRelay.stopWasRequested {
                    // The chat reply composer released this content at optimistic
                    // persistence and may hold the next reply. Nothing reached
                    // Gmail, so keeping the row as definitely unsent is
                    // duplicate-safe; resend is only the explicit Edit and resend.
                    Log.info(
                        "Retaining reply that failed before transmission as not sent",
                        category: .message
                    )
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
                        admission: admission,
                        error: error
                    )
                }
            }
            // Covers failures before the send worker existed; idempotent.
            await sendOrderTurn?.finish()
            await backgroundLease.end()
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

    /// Rolls back a pre-barrier failure and resolves admission to match what
    /// the rollback did. A rollback that had to retain the row as "Not sent"
    /// (`PreTransmissionRollbackOutcome.retainedAsNotSent`) succeeds
    /// admission: the bubble owns the content, so the caller must not also
    /// get it back.
    private func handleDefiniteFailure(
        sendService: ComposeSendServicing,
        attachmentReferences: [LocalAttachmentReference],
        optimisticMessageID: String,
        reconciliationHooks: OutboundMessageReconciliationHooks,
        admission: ComposeSendTransmissionAdmission,
        error: Error
    ) async {
        let outcome = await MainActor.run {
            let outcome = sendService.rollbackOptimisticMessageBeforeTransmission(
                byID: optimisticMessageID,
                fallbackAttachmentReferences: attachmentReferences
            )
            // A cancellation's description is not a reason the user can act
            // on; the bubble's generic "not sent" text reads better.
            if outcome == .retainedAsNotSent, !(error is CancellationError) {
                sendService.recordSendFailureReason(
                    optimisticMessageID: optimisticMessageID,
                    reason: error.localizedDescription
                )
            }
            reconciliationHooks.onFailure?(
                .init(
                    optimisticMessageID: optimisticMessageID,
                    errorDescription: error.localizedDescription
                )
            )
            return outcome
        }
        Log.error("Background send failed", category: .message, error: error)
        switch outcome {
        case .rolledBack:
            await admission.fail(error)
        case .retainedAsNotSent:
            await admission.succeed()
        }
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
            sendService.recordSendFailureReason(optimisticMessageID: optimisticMessageID, reason: error.localizedDescription)
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
