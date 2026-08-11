import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class ComposeSendOrchestratorTests: XCTestCase {
    func testExecuteInBackground_newMessage_runsSendNewAndSync() async {
        let sendService = MockComposeSendService()
        let syncPerformer = MockIncrementalSyncPerformer()
        let orchestrator = ComposeSendOrchestrator(sendService: sendService, syncPerformer: syncPerformer)

        let task = orchestrator.executeInBackground(
            input: makeInput(),
            attachmentReferences: [],
            optimisticMessageID: "optimistic-1"
        )
        await task.task.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.markUploadedCalls, 1)
        XCTAssertEqual(snapshot.sendNewCalls, 1)
        XCTAssertEqual(snapshot.sendReplyCalls, 0)
        XCTAssertEqual(snapshot.remoteTransmissionCalls, 1)
        XCTAssertEqual(snapshot.recordRemoteSendAdmissionCalls, ["optimistic-1"])
        XCTAssertTrue(snapshot.recordAmbiguousRemoteSendCalls.isEmpty)
        XCTAssertEqual(snapshot.markFailedCalls, 0)
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 1)
    }

    func testExecuteInBackground_successMarksProvidedAttachmentReferencesUploaded() async {
        let sendService = MockComposeSendService()
        let syncPerformer = MockIncrementalSyncPerformer()
        let orchestrator = ComposeSendOrchestrator(sendService: sendService, syncPerformer: syncPerformer)
        let attachmentReference = LocalAttachmentReference(
            persistentStoreURI: URL(string: "x-coredata://attachment/1")!
        )

        let task = orchestrator.executeInBackground(
            input: makeInput(),
            attachmentReferences: [attachmentReference],
            optimisticMessageID: "optimistic-1a"
        )
        await task.task.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.markUploadedCalls, 1)
        XCTAssertEqual(snapshot.uploadedAttachmentReferences, [attachmentReference])
    }

    func testExecuteInBackground_reply_runsSendReplyAndSync() async {
        let sendService = MockComposeSendService()
        let syncPerformer = MockIncrementalSyncPerformer()
        let orchestrator = ComposeSendOrchestrator(sendService: sendService, syncPerformer: syncPerformer)

        let replyMetadata = OutboundMessageRequest.ReplyMetadata(
            recipientEmails: ["to@example.com"],
            fromEmail: "alias@example.com",
            fromName: "Alias",
            subject: "Re: Hello",
            threadId: "thread-1",
            inReplyTo: "<id-1>",
            references: ["<id-1>"],
            originalMessage: nil
        )

        let task = orchestrator.executeInBackground(
            input: makeInput(body: "reply body", replyMetadata: replyMetadata),
            attachmentReferences: [],
            optimisticMessageID: "optimistic-2"
        )
        await task.task.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.sendNewCalls, 0)
        XCTAssertEqual(snapshot.sendReplyCalls, 1)
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 1)
    }

    func testExecuteInBackground_replyWithoutSubject_stillRunsSendReplyAndSync() async {
        let sendService = MockComposeSendService()
        let syncPerformer = MockIncrementalSyncPerformer()
        let orchestrator = ComposeSendOrchestrator(sendService: sendService, syncPerformer: syncPerformer)

        let replyMetadata = OutboundMessageRequest.ReplyMetadata(
            recipientEmails: ["to@example.com"],
            fromEmail: "alias@example.com",
            fromName: "Alias",
            subject: nil,
            threadId: "thread-1",
            inReplyTo: "<id-1>",
            references: ["<id-1>"],
            originalMessage: nil
        )

        let task = orchestrator.executeInBackground(
            input: makeInput(body: "reply body", replyMetadata: replyMetadata),
            attachmentReferences: [],
            optimisticMessageID: "optimistic-2b"
        )
        await task.task.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.sendNewCalls, 0)
        XCTAssertEqual(snapshot.sendReplyCalls, 1)
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 1)
    }

    func testExecuteInBackground_cancellationDrainsInFlightSendAndSkipsSync() async {
        let sendService = MockComposeSendService()
        sendService.sendDelayNanoseconds = 100_000_000

        let syncPerformer = MockIncrementalSyncPerformer()
        let orchestrator = ComposeSendOrchestrator(sendService: sendService, syncPerformer: syncPerformer)

        let task = orchestrator.executeInBackground(
            input: makeInput(),
            attachmentReferences: [],
            optimisticMessageID: "optimistic-3"
        )

        while sendService.snapshot.sendNewCalls == 0 {
            await Task.yield()
        }
        task.task.cancel()
        await task.task.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.sendNewCalls, 1)
        XCTAssertEqual(snapshot.rollbackBeforeTransmissionCalls, 0)
        XCTAssertEqual(snapshot.recordRemoteSendAdmissionCalls, ["optimistic-3"])
        XCTAssertTrue(snapshot.recordAmbiguousRemoteSendCalls.isEmpty)
        XCTAssertEqual(snapshot.recordRemoteCommittedSendCalls, ["optimistic-3"])
        XCTAssertEqual(snapshot.reconcileRemoteCommittedSendCalls, ["optimistic-3"])
        XCTAssertEqual(snapshot.markUploadedCalls, 1)
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 0)
    }

    func testExecuteInBackground_cancelBeforeWorkerInstallationCancelsNestedSend() async {
        let sendService = MockComposeSendService()
        let syncPerformer = MockIncrementalSyncPerformer()
        let orchestrator = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: syncPerformer
        )

        let operation = orchestrator.executeInBackground(
            input: makeInput(),
            attachmentReferences: [],
            optimisticMessageID: "optimistic-cancel-before-install",
            transmissionAdmission: {
                try Task.checkCancellation()
                try sendService.recordRemoteSendAdmission(
                    optimisticMessageID: "optimistic-cancel-before-install"
                )
            }
        )

        // MainActor has not yielded since operation creation, so the detached
        // worker cannot yet have completed its first MainActor preflight hop.
        operation.cancelBeforeTransmission()
        await operation.task.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.sendNewCalls, 1)
        XCTAssertEqual(snapshot.remoteTransmissionCalls, 0)
        XCTAssertTrue(snapshot.recordRemoteSendAdmissionCalls.isEmpty)
        XCTAssertEqual(snapshot.rollbackBeforeTransmissionCalls, 1)
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 0)
    }

    func testExecuteInBackground_directAmbiguousCancellationDoesNotInvokeFailureHook() async {
        let sendService = MockComposeSendService()
        sendService.sendNewError = CancellationError()
        let syncPerformer = MockIncrementalSyncPerformer()
        let orchestrator = ComposeSendOrchestrator(sendService: sendService, syncPerformer: syncPerformer)
        var failureIDs: [String] = []
        var ambiguousIDs: [String] = []
        let attachmentReference = LocalAttachmentReference(
            persistentStoreURI: URL(string: "x-coredata://attachment/ambiguous")!
        )

        let task = orchestrator.executeInBackground(
            input: makeInput(),
            attachmentReferences: [attachmentReference],
            optimisticMessageID: "optimistic-cooperative-cancel",
            reconciliationHooks: .init(
                onSuccess: nil,
                onFailure: { failure in failureIDs.append(failure.optimisticMessageID) },
                onAmbiguous: { ambiguous in ambiguousIDs.append(ambiguous.optimisticMessageID) }
            )
        )
        await task.task.value

        XCTAssertEqual(sendService.snapshot.rollbackBeforeTransmissionCalls, 0)
        XCTAssertEqual(
            sendService.snapshot.recordRemoteSendAdmissionCalls,
            ["optimistic-cooperative-cancel"]
        )
        XCTAssertEqual(
            sendService.snapshot.recordAmbiguousRemoteSendCalls,
            ["optimistic-cooperative-cancel"]
        )
        XCTAssertTrue(failureIDs.isEmpty)
        XCTAssertEqual(ambiguousIDs, ["optimistic-cooperative-cancel"])
        XCTAssertEqual(sendService.snapshot.retainDefinitelyUnsentCalls, 0)
        XCTAssertEqual(sendService.snapshot.markUploadedCalls, 1)
        XCTAssertEqual(
            sendService.snapshot.uploadedAttachmentReferences,
            [attachmentReference]
        )
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 0)
    }

    func testExecuteInBackground_postAdmissionDefiniteFailureRetainsOptimisticMessage() async {
        let sendService = MockComposeSendService()
        sendService.sendNewError = GmailSendService.SendError.apiError("boom")

        let syncPerformer = MockIncrementalSyncPerformer()
        let orchestrator = ComposeSendOrchestrator(sendService: sendService, syncPerformer: syncPerformer)
        var failureIDs: [String] = []

        let task = orchestrator.executeInBackground(
            input: makeInput(),
            attachmentReferences: [],
            optimisticMessageID: "optimistic-failure",
            reconciliationHooks: .init(
                onSuccess: nil,
                onFailure: { failure in failureIDs.append(failure.optimisticMessageID) }
            )
        )
        await task.task.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.sendNewCalls, 1)
        XCTAssertEqual(snapshot.rollbackBeforeTransmissionCalls, 0)
        XCTAssertEqual(snapshot.retainDefinitelyUnsentCalls, 1)
        XCTAssertEqual(
            snapshot.recordRemoteSendAdmissionCalls,
            ["optimistic-failure"]
        )
        XCTAssertTrue(snapshot.recordAmbiguousRemoteSendCalls.isEmpty)
        XCTAssertEqual(snapshot.markFailedCalls, 0)
        XCTAssertEqual(failureIDs, ["optimistic-failure"])
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 0)
    }

    func testExecuteInBackground_preflightFailureIsDefiniteAndDoesNotPersistBarrier() async {
        let sendService = MockComposeSendService()
        sendService.sendNewPreflightError = GmailSendService.SendError.apiError("preflight")
        let syncPerformer = MockIncrementalSyncPerformer()
        let attachmentReference = LocalAttachmentReference(
            persistentStoreURI: URL(string: "x-coredata://attachment/preflight")!
        )
        let orchestrator = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: syncPerformer
        )

        let task = orchestrator.executeInBackground(
            input: makeInput(),
            attachmentReferences: [attachmentReference],
            optimisticMessageID: "optimistic-preflight-failure"
        )
        await task.task.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.sendNewCalls, 1)
        XCTAssertEqual(snapshot.remoteTransmissionCalls, 0)
        XCTAssertTrue(snapshot.recordRemoteSendAdmissionCalls.isEmpty)
        XCTAssertTrue(snapshot.recordAmbiguousRemoteSendCalls.isEmpty)
        XCTAssertEqual(snapshot.rollbackBeforeTransmissionCalls, 1)
        XCTAssertEqual(snapshot.failedAttachmentReferences, [attachmentReference])
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 0)
    }

    func testExecuteInBackground_preflightCancellationIsDefiniteAndRecoverable() async {
        let sendService = MockComposeSendService()
        sendService.sendNewPreflightError = CancellationError()
        let syncPerformer = MockIncrementalSyncPerformer()
        let orchestrator = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: syncPerformer
        )

        let task = orchestrator.executeInBackground(
            input: makeInput(),
            attachmentReferences: [],
            optimisticMessageID: "optimistic-preflight-cancel"
        )
        await task.task.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.sendNewCalls, 1)
        XCTAssertEqual(snapshot.remoteTransmissionCalls, 0)
        XCTAssertTrue(snapshot.recordRemoteSendAdmissionCalls.isEmpty)
        XCTAssertTrue(snapshot.recordAmbiguousRemoteSendCalls.isEmpty)
        XCTAssertEqual(snapshot.rollbackBeforeTransmissionCalls, 1)
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 0)
    }

    func testExecuteInBackground_markerPersistenceFailureDoesNotBeginSend() async {
        let sendService = MockComposeSendService()
        sendService.recordRemoteSendAdmissionError =
            GmailSendService.SendError.optimisticCreationFailed
        let syncPerformer = MockIncrementalSyncPerformer()
        let orchestrator = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: syncPerformer
        )

        let task = orchestrator.executeInBackground(
            input: makeInput(),
            attachmentReferences: [],
            optimisticMessageID: "optimistic-barrier-failure"
        )
        await task.task.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.sendNewCalls, 1)
        XCTAssertEqual(snapshot.sendReplyCalls, 0)
        XCTAssertEqual(snapshot.remoteTransmissionCalls, 0)
        XCTAssertEqual(snapshot.rollbackBeforeTransmissionCalls, 1)
        XCTAssertEqual(
            snapshot.recordRemoteSendAdmissionCalls,
            ["optimistic-barrier-failure"]
        )
        XCTAssertTrue(snapshot.recordAmbiguousRemoteSendCalls.isEmpty)
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 0)
    }

    func testExecuteInBackground_sendFailurePassesFallbackAttachmentReferences() async {
        let sendService = MockComposeSendService()
        sendService.sendNewError = GmailSendService.SendError.apiError("boom")
        let syncPerformer = MockIncrementalSyncPerformer()
        let orchestrator = ComposeSendOrchestrator(sendService: sendService, syncPerformer: syncPerformer)
        let attachmentReference = LocalAttachmentReference(
            persistentStoreURI: URL(string: "x-coredata://attachment/2")!
        )

        let task = orchestrator.executeInBackground(
            input: makeInput(),
            attachmentReferences: [attachmentReference],
            optimisticMessageID: "optimistic-failure-refs"
        )
        await task.task.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.rollbackBeforeTransmissionCalls, 0)
        XCTAssertEqual(snapshot.retainDefinitelyUnsentCalls, 1)
        XCTAssertEqual(snapshot.failedAttachmentReferences, [attachmentReference])
    }

    func testExecuteInBackground_remoteCommittedRetrySkipsRemoteSendAndReconcilesLocally() async {
        let sendService = MockComposeSendService()
        sendService.reconcileRemoteCommittedSendError = GmailSendService.SendError.optimisticCreationFailed
        let syncPerformer = MockIncrementalSyncPerformer()
        let orchestrator = ComposeSendOrchestrator(sendService: sendService, syncPerformer: syncPerformer)

        let firstTask = orchestrator.executeInBackground(
            input: makeInput(),
            attachmentReferences: [],
            optimisticMessageID: "optimistic-remote-committed"
        )
        await firstTask.task.value

        var snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.sendNewCalls, 1)
        XCTAssertEqual(snapshot.recordRemoteCommittedSendCalls, ["optimistic-remote-committed"])
        XCTAssertEqual(snapshot.reconcileRemoteCommittedSendCalls, ["optimistic-remote-committed"])
        XCTAssertEqual(snapshot.rollbackBeforeTransmissionCalls, 0)

        sendService.reconcileRemoteCommittedSendError = nil

        let retryTask = orchestrator.executeInBackground(
            input: makeInput(),
            attachmentReferences: [],
            optimisticMessageID: "optimistic-remote-committed"
        )
        await retryTask.task.value

        snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.sendNewCalls, 1, "Retry must not send a second Gmail message")
        XCTAssertEqual(
            snapshot.reconcileRemoteCommittedSendCalls,
            ["optimistic-remote-committed", "optimistic-remote-committed"]
        )
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 2)
    }

    private func makeInput(
        body: String = "hello",
        replyMetadata: OutboundMessageRequest.ReplyMetadata? = nil
    ) -> ComposeSendOrchestrator.SendInput {
        ComposeSendOrchestrator.SendInput(
            recipientEmails: ["to@example.com"],
            body: body,
            htmlBody: nil,
            subject: "Subject",
            attachmentInfos: [],
            inlineAttachmentInfos: [],
            replyMetadata: replyMetadata
        )
    }
}

@MainActor
private final class MockIncrementalSyncPerformer: IncrementalSyncPerforming {
    private(set) var performIncrementalSyncCalls = 0

    func performIncrementalSync() async throws {
        performIncrementalSyncCalls += 1
    }
}

private final class MockComposeSendService: ComposeSendServicing {
    struct Snapshot {
        let markUploadedCalls: Int
        let sendNewCalls: Int
        let sendReplyCalls: Int
        let remoteTransmissionCalls: Int
        let updateOptimisticCalls: Int
        let markFailedCalls: Int
        let rollbackBeforeTransmissionCalls: Int
        let retainDefinitelyUnsentCalls: Int
        let recordRemoteSendAdmissionCalls: [String]
        let recordAmbiguousRemoteSendCalls: [String]
        let recordRemoteCommittedSendCalls: [String]
        let reconcileRemoteCommittedSendCalls: [String]
        let uploadedAttachmentReferences: [LocalAttachmentReference]
        let failedAttachmentReferences: [LocalAttachmentReference]
    }

    private let queue = DispatchQueue(label: "ComposeSendOrchestratorTests.MockComposeSendService")

    var sendDelayNanoseconds: UInt64 = 0
    var sendNewPreflightError: Error?
    var sendNewError: Error?
    var sendReplyError: Error?
    var recordRemoteSendAdmissionError: Error?
    var recordAmbiguousRemoteSendError: Error?
    var reconcileRemoteCommittedSendError: Error?

    private var _markUploadedCalls = 0
    private var _sendNewCalls = 0
    private var _sendReplyCalls = 0
    private var _remoteTransmissionCalls = 0
    private var _updateOptimisticCalls = 0
    private var _markFailedCalls = 0
    private var _rollbackBeforeTransmissionCalls = 0
    private var _retainDefinitelyUnsentCalls = 0
    private var _recordRemoteSendAdmissionCalls: [String] = []
    private var _recordAmbiguousRemoteSendCalls: [String] = []
    private var _recordRemoteCommittedSendCalls: [String] = []
    private var _reconcileRemoteCommittedSendCalls: [String] = []
    private var _remoteCommittedResults: [String: GmailSendService.SendResult] = [:]
    private var _uploadedAttachmentReferences: [LocalAttachmentReference] = []
    private var _failedAttachmentReferences: [LocalAttachmentReference] = []

    var snapshot: Snapshot {
        queue.sync {
            Snapshot(
                markUploadedCalls: _markUploadedCalls,
                sendNewCalls: _sendNewCalls,
                sendReplyCalls: _sendReplyCalls,
                remoteTransmissionCalls: _remoteTransmissionCalls,
                updateOptimisticCalls: _updateOptimisticCalls,
                markFailedCalls: _markFailedCalls,
                rollbackBeforeTransmissionCalls: _rollbackBeforeTransmissionCalls,
                retainDefinitelyUnsentCalls: _retainDefinitelyUnsentCalls,
                recordRemoteSendAdmissionCalls: _recordRemoteSendAdmissionCalls,
                recordAmbiguousRemoteSendCalls: _recordAmbiguousRemoteSendCalls,
                recordRemoteCommittedSendCalls: _recordRemoteCommittedSendCalls,
                reconcileRemoteCommittedSendCalls: _reconcileRemoteCommittedSendCalls,
                uploadedAttachmentReferences: _uploadedAttachmentReferences,
                failedAttachmentReferences: _failedAttachmentReferences
            )
        }
    }

    @MainActor
    func markAttachmentsAsUploaded(references: [LocalAttachmentReference]) {
        queue.sync {
            _markUploadedCalls += 1
            _uploadedAttachmentReferences = references
        }
    }

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
    ) async throws -> GmailSendService.SendResult {
        queue.sync { _sendReplyCalls += 1 }

        try await beforeTransmission()
        queue.sync { _remoteTransmissionCalls += 1 }

        if sendDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: sendDelayNanoseconds)
        }
        if let sendReplyError {
            throw sendReplyError
        }
        return GmailSendService.SendResult(messageId: "sent-id", threadId: "thread-id")
    }

    func sendNew(
        to recipients: [String],
        body: String,
        htmlBody: String?,
        subject: String?,
        attachmentInfos: [GmailSendService.AttachmentInfo],
        inlineAttachmentInfos: [GmailSendService.AttachmentInfo],
        messageId: String?,
        beforeTransmission: @Sendable () async throws -> Void
    ) async throws -> GmailSendService.SendResult {
        queue.sync { _sendNewCalls += 1 }

        if let sendNewPreflightError {
            throw sendNewPreflightError
        }

        try await beforeTransmission()
        queue.sync { _remoteTransmissionCalls += 1 }

        if sendDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: sendDelayNanoseconds)
        }
        if let sendNewError {
            throw sendNewError
        }
        return GmailSendService.SendResult(messageId: "sent-id", threadId: "thread-id")
    }

    @MainActor
    func remoteCommittedSendResult(optimisticMessageID: String) -> GmailSendService.SendResult? {
        queue.sync {
            _remoteCommittedResults[optimisticMessageID]
        }
    }

    @MainActor
    func persistOptimisticMessageBeforeTransmission(optimisticMessageID: String) throws {}

    @MainActor
    func recordRemoteSendAdmission(optimisticMessageID: String) throws {
        try queue.sync {
            _recordRemoteSendAdmissionCalls.append(optimisticMessageID)
            if let recordRemoteSendAdmissionError {
                throw recordRemoteSendAdmissionError
            }
        }
    }

    @MainActor
    func recordAmbiguousRemoteSend(optimisticMessageID: String) throws {
        try queue.sync {
            _recordAmbiguousRemoteSendCalls.append(optimisticMessageID)
            if let recordAmbiguousRemoteSendError {
                throw recordAmbiguousRemoteSendError
            }
        }
    }

    @MainActor
    func recordRemoteCommittedSend(
        optimisticMessageID: String,
        result: GmailSendService.SendResult
    ) throws {
        queue.sync {
            _recordRemoteCommittedSendCalls.append(optimisticMessageID)
            _remoteCommittedResults[optimisticMessageID] = result
        }
    }

    @MainActor
    func reconcileRemoteCommittedSend(
        optimisticMessageID: String,
        result: GmailSendService.SendResult
    ) throws -> Bool {
        try queue.sync {
            _reconcileRemoteCommittedSendCalls.append(optimisticMessageID)
            if let reconcileRemoteCommittedSendError {
                throw reconcileRemoteCommittedSendError
            }

            _remoteCommittedResults[optimisticMessageID] = nil
            return true
        }
    }

    @MainActor
    func fetchMessageSync(byID messageID: String) -> Message? {
        nil
    }

    @MainActor
    func updateOptimisticMessage(_ message: Message, with result: GmailSendService.SendResult) {
        queue.sync { _updateOptimisticCalls += 1 }
    }

    @MainActor
    func rollbackOptimisticMessageBeforeTransmission(
        byID messageID: String,
        fallbackAttachmentReferences: [LocalAttachmentReference]
    ) {
        queue.sync {
            _rollbackBeforeTransmissionCalls += 1
            _failedAttachmentReferences = fallbackAttachmentReferences
        }
    }

    @MainActor
    func retainDefinitelyUnsentOptimisticMessage(
        byID messageID: String,
        fallbackAttachmentReferences: [LocalAttachmentReference]
    ) {
        queue.sync {
            _retainDefinitelyUnsentCalls += 1
            _failedAttachmentReferences = fallbackAttachmentReferences
        }
    }
}
