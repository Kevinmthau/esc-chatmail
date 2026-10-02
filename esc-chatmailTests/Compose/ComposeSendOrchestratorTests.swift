import XCTest
import CoreData
import UIKit
@testable import esc_chatmail

@MainActor
final class ComposeSendOrchestratorTests: XCTestCase {
    func testBackgroundLeaseCoversLocalCommitAndEndsBeforeOptionalSync() async {
        let sendService = MockComposeSendService()
        let syncPerformer = MockIncrementalSyncPerformer()
        let backgroundTasks = MockOutboundBackgroundTaskManager()
        backgroundTasks.onEnd = {
            XCTAssertEqual(sendService.snapshot.recordRemoteCommittedSendCalls, ["lease-success"])
            XCTAssertEqual(sendService.snapshot.reconcileRemoteCommittedSendCalls, ["lease-success"])
            XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 0)
        }

        let operation = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: syncPerformer,
            backgroundTaskManager: backgroundTasks
        ).executeInBackground(input: makeInput(), attachmentReferences: [], optimisticMessageID: "lease-success")
        XCTAssertEqual(backgroundTasks.beginCalls, 1, "Acquire time before detached preflight starts")
        await operation.task.value

        XCTAssertEqual(backgroundTasks.endedIdentifiers, [backgroundTasks.identifier])
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 1)
        backgroundTasks.expire()
        XCTAssertEqual(backgroundTasks.endedIdentifiers.count, 1, "A late expiration cannot end a completed lease twice")
    }

    func testBackgroundLeaseEndsAfterPreflightFailureCleanup() async {
        let sendService = MockComposeSendService()
        sendService.sendNewPreflightError = GmailSendService.SendError.apiError("Attachment missing")
        let backgroundTasks = MockOutboundBackgroundTaskManager()
        backgroundTasks.onEnd = {
            XCTAssertEqual(sendService.snapshot.rollbackBeforeTransmissionCalls, 1)
        }
        let operation = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: MockIncrementalSyncPerformer(),
            backgroundTaskManager: backgroundTasks
        ).executeInBackground(input: makeInput(), attachmentReferences: [], optimisticMessageID: "lease-failure")
        await operation.task.value

        XCTAssertEqual(backgroundTasks.endedIdentifiers, [backgroundTasks.identifier])
        XCTAssertEqual(sendService.snapshot.remoteTransmissionCalls, 0)
    }

    func testBackgroundExpirationBeforeWorkerInstallationPreventsTransmission() async {
        let sendService = MockComposeSendService()
        let backgroundTasks = MockOutboundBackgroundTaskManager()
        let operation = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: MockIncrementalSyncPerformer(),
            backgroundTaskManager: backgroundTasks
        ).executeInBackground(input: makeInput(), attachmentReferences: [], optimisticMessageID: "lease-preflight")

        // MainActor has not yielded to the worker's first persistence hop yet.
        backgroundTasks.expire()
        XCTAssertEqual(backgroundTasks.endedIdentifiers.count, 1, "Return UIKit's time immediately")
        await operation.task.value
        do {
            try await operation.waitForTransmissionAdmission()
            XCTFail("Expired preflight must not be admitted")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(sendService.snapshot.remoteTransmissionCalls, 0)
        XCTAssertEqual(sendService.snapshot.rollbackBeforeTransmissionCalls, 1)
        XCTAssertTrue(sendService.snapshot.recordRemoteSendAdmissionCalls.isEmpty)
        XCTAssertTrue(sendService.snapshot.recordAmbiguousRemoteSendCalls.isEmpty)
        XCTAssertEqual(backgroundTasks.endedIdentifiers.count, 1)
    }

    func testBackgroundExpirationAfterAdmissionRetainsUnknownDeliveryWithoutRetry() async throws {
        let sendService = MockComposeSendService()
        sendService.sendDelayNanoseconds = 5_000_000_000
        let syncPerformer = MockIncrementalSyncPerformer()
        let backgroundTasks = MockOutboundBackgroundTaskManager()
        let operation = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: syncPerformer,
            backgroundTaskManager: backgroundTasks
        ).executeInBackground(input: makeInput(), attachmentReferences: [], optimisticMessageID: "lease-admitted")
        try await operation.waitForTransmissionAdmission()

        backgroundTasks.expire()
        XCTAssertEqual(backgroundTasks.endedIdentifiers.count, 1)
        await operation.task.value

        XCTAssertEqual(sendService.snapshot.sendNewCalls, 1)
        XCTAssertEqual(sendService.snapshot.recordAmbiguousRemoteSendCalls, ["lease-admitted"])
        XCTAssertEqual(sendService.snapshot.rollbackBeforeTransmissionCalls, 0)
        XCTAssertEqual(sendService.snapshot.retainDefinitelyUnsentCalls, 0)
        XCTAssertTrue(sendService.snapshot.recordRemoteCommittedSendCalls.isEmpty)
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 0)
        XCTAssertEqual(backgroundTasks.endedIdentifiers.count, 1)
    }

    func testDeniedBackgroundTimeStillAllowsForegroundSend() async {
        let sendService = MockComposeSendService()
        let backgroundTasks = MockOutboundBackgroundTaskManager()
        backgroundTasks.identifier = .invalid
        let operation = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: MockIncrementalSyncPerformer(),
            backgroundTaskManager: backgroundTasks
        ).executeInBackground(input: makeInput(), attachmentReferences: [], optimisticMessageID: "lease-denied")
        await operation.task.value

        XCTAssertEqual(sendService.snapshot.recordRemoteCommittedSendCalls, ["lease-denied"])
        XCTAssertTrue(backgroundTasks.endedIdentifiers.isEmpty)
    }

    func testSynchronousBackgroundExpirationReturnsTheAcquiredIdentifierOnce() {
        let backgroundTasks = MockOutboundBackgroundTaskManager()
        backgroundTasks.expiresDuringBegin = true
        var expirationCalls = 0
        let lease = OutboundSendBackgroundLease(manager: backgroundTasks) {
            expirationCalls += 1
        }
        lease.end()
        backgroundTasks.expire()

        XCTAssertEqual(expirationCalls, 1)
        XCTAssertEqual(backgroundTasks.endedIdentifiers, [backgroundTasks.identifier])
    }

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

    func testExecuteInBackground_replyResolvesDeferredHTMLDuringDetachedPreflight() async {
        let sendService = MockComposeSendService()
        let syncPerformer = MockIncrementalSyncPerformer()
        let probe = ReplyResolutionProbe(result: "<html><body>Resolved HTML</body></html>")
        let resolver = ReplyQuotedHTMLResolver { source in
            probe.load(source)
        }
        let originalMessage = QuotedMessage(
            senderName: "Friend",
            senderEmail: "friend@example.com",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            body: "Original body",
            deferredOriginalHTML: DeferredReplyQuotedHTML(
                source: ReplyQuotedHTMLSource(
                    messageId: "deferred-message",
                    bodyStorageURI: nil,
                    bodyText: "Original body",
                    senderEmail: "friend@example.com",
                    subject: "Hello"
                ),
                resolver: resolver
            )
        )
        let metadata = OutboundMessageRequest.ReplyMetadata(
            recipientEmails: ["to@example.com"],
            fromEmail: "alias@example.com",
            fromName: "Alias",
            subject: "Re: Hello",
            threadId: "thread-1",
            inReplyTo: "<id-1>",
            references: ["<id-1>"],
            originalMessage: originalMessage
        )

        let operation = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: syncPerformer
        ).executeInBackground(
            input: makeInput(body: "reply body", replyMetadata: metadata),
            attachmentReferences: [],
            optimisticMessageID: "optimistic-deferred-html"
        )
        await operation.task.value

        let resolutionSnapshot = probe.snapshot
        XCTAssertEqual(resolutionSnapshot.messageIDs, ["deferred-message"])
        XCTAssertEqual(resolutionSnapshot.mainThreadObservations, [false])
        XCTAssertEqual(
            sendService.snapshot.lastReplyOriginalHTML,
            "<html><body>Resolved HTML</body></html>"
        )
        XCTAssertFalse(sendService.snapshot.lastReplyHadDeferredOriginalHTML)
    }

    func testExecuteInBackground_explicitReplyHTMLSkipsDeferredResolution() async {
        let sendService = MockComposeSendService()
        let syncPerformer = MockIncrementalSyncPerformer()
        let probe = ReplyResolutionProbe(result: "<html><body>Deferred HTML</body></html>")
        let resolver = ReplyQuotedHTMLResolver { source in
            probe.load(source)
        }
        let originalMessage = QuotedMessage(
            senderName: "Friend",
            senderEmail: "friend@example.com",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            body: "Original body",
            originalHTML: "<html><body>Explicit HTML</body></html>",
            deferredOriginalHTML: DeferredReplyQuotedHTML(
                source: ReplyQuotedHTMLSource(
                    messageId: "unused-deferred-message",
                    bodyStorageURI: nil,
                    bodyText: "Original body",
                    senderEmail: "friend@example.com",
                    subject: "Hello"
                ),
                resolver: resolver
            )
        )
        let metadata = OutboundMessageRequest.ReplyMetadata(
            recipientEmails: ["to@example.com"],
            fromEmail: "alias@example.com",
            fromName: "Alias",
            subject: "Re: Hello",
            threadId: "thread-1",
            inReplyTo: "<id-1>",
            references: ["<id-1>"],
            originalMessage: originalMessage
        )

        let operation = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: syncPerformer
        ).executeInBackground(
            input: makeInput(body: "reply body", replyMetadata: metadata),
            attachmentReferences: [],
            optimisticMessageID: "optimistic-explicit-html"
        )
        await operation.task.value

        XCTAssertTrue(probe.snapshot.messageIDs.isEmpty)
        XCTAssertEqual(
            sendService.snapshot.lastReplyOriginalHTML,
            "<html><body>Explicit HTML</body></html>"
        )
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

    func testExecuteInBackground_replyWithoutThreadIdNeverRunsSendNew() async {
        let sendService = MockComposeSendService()
        let syncPerformer = MockIncrementalSyncPerformer()
        let orchestrator = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: syncPerformer
        )
        let replyMetadata = OutboundMessageRequest.ReplyMetadata(
            recipientEmails: ["to@example.com"],
            fromEmail: "alias@example.com",
            fromName: "Alias",
            subject: "Re: Hello",
            threadId: nil,
            inReplyTo: "<id-1>",
            references: ["<id-1>"],
            originalMessage: nil
        )

        let operation = orchestrator.executeInBackground(
            input: makeInput(body: "reply body", replyMetadata: replyMetadata),
            attachmentReferences: [],
            optimisticMessageID: "optimistic-missing-reply-thread"
        )
        await operation.task.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.sendNewCalls, 0)
        XCTAssertEqual(snapshot.sendReplyCalls, 0)
        XCTAssertEqual(snapshot.rollbackBeforeTransmissionCalls, 1)
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 0)
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

    func testExecuteInBackground_sameConversationSecondSendWaitsForFirstToFinish() async throws {
        let sendService = MockComposeSendService()
        let firstGate = TransmissionTestGate()
        sendService.postAdmissionGatesByBody = ["first": firstGate]
        let sequencer = OutboundConversationSendSequencer()
        let conversation = ConversationReference(
            persistentStoreURI: URL(string: "x-coredata://conversation/fifo-order")!
        )
        let orchestrator = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: MockIncrementalSyncPerformer()
        )

        let first = orchestrator.executeInBackground(
            input: makeInput(body: "first"),
            attachmentReferences: [],
            optimisticMessageID: "fifo-first",
            sendOrderTurn: sequencer.enqueue(conversation: conversation)
        )
        let second = orchestrator.executeInBackground(
            input: makeInput(body: "second"),
            attachmentReferences: [],
            optimisticMessageID: "fifo-second",
            sendOrderTurn: sequencer.enqueue(conversation: conversation)
        )
        await firstGate.waitUntilEntered()
        await waitUntil { sequencer.suspendedTurnCount == 1 }

        // The first reply is uploading; the second has finished everything up
        // to its turn and is parked strictly before its barrier.
        // Revert-check: deleting `try await sendOrderTurn?.waitUntilFront()`
        // from the `sendNew` branch of `ComposeSendOrchestrator` admits the
        // second send now, and no turn is ever suspended.
        XCTAssertEqual(sendService.snapshot.recordRemoteSendAdmissionCalls, ["fifo-first"])
        XCTAssertEqual(sendService.snapshot.remoteTransmissionCalls, 1)

        await firstGate.open()
        await first.task.value
        try await second.waitForTransmissionAdmission()
        await second.task.value

        XCTAssertEqual(
            sendService.snapshot.recordRemoteSendAdmissionCalls,
            ["fifo-first", "fifo-second"]
        )
        XCTAssertEqual(sendService.snapshot.remoteTransmissionCalls, 2)
        XCTAssertEqual(sequencer.suspendedTurnCount, 0)
    }

    func testExecuteInBackground_waitingSendIsCancelledBeforeTransmissionWithoutWaitingForFirst() async {
        let sendService = MockComposeSendService()
        let firstGate = TransmissionTestGate()
        sendService.postAdmissionGatesByBody = ["first": firstGate]
        let sequencer = OutboundConversationSendSequencer()
        let conversation = ConversationReference(
            persistentStoreURI: URL(string: "x-coredata://conversation/fifo-cancel")!
        )
        let orchestrator = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: MockIncrementalSyncPerformer()
        )

        let first = orchestrator.executeInBackground(
            input: makeInput(body: "first"),
            attachmentReferences: [],
            optimisticMessageID: "fifo-cancel-first",
            sendOrderTurn: sequencer.enqueue(conversation: conversation)
        )
        let second = orchestrator.executeInBackground(
            input: makeInput(body: "second"),
            attachmentReferences: [],
            optimisticMessageID: "fifo-cancel-second",
            preTransmissionFailureDisposition: .retainAsNotSent,
            sendOrderTurn: sequencer.enqueue(conversation: conversation)
        )
        await firstGate.waitUntilEntered()
        await waitUntil { sequencer.suspendedTurnCount == 1 }
        var secondFinished = false
        let secondWatcher = Task { @MainActor in
            await second.task.value
            secondFinished = true
        }

        // What `OutboundTaskRegistry.closeAdmission` invokes for a preflight
        // entry. The waiting send must unwind while the first is still out.
        // Revert-check: dropping the `onCancel` handler from
        // `OutboundConversationSendSequencer.waitUntilFront` leaves the second
        // send parked until the first finishes, and this wait times out.
        second.cancelBeforeTransmission()
        await waitUntil { secondFinished }

        XCTAssertEqual(sendService.snapshot.recordRemoteSendAdmissionCalls, ["fifo-cancel-first"])
        XCTAssertEqual(sendService.snapshot.remoteTransmissionCalls, 1)
        // Teardown rolls back even a `.retainAsNotSent` send.
        XCTAssertEqual(sendService.snapshot.rollbackBeforeTransmissionCalls, 1)
        XCTAssertEqual(sendService.snapshot.retainDefinitelyUnsentCalls, 0)

        // Opened only now, so a failing run still unwinds instead of hanging.
        await firstGate.open()
        await first.task.value
        await secondWatcher.value
        do {
            try await second.waitForTransmissionAdmission()
            XCTFail("A cancelled waiting send must not be admitted")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(sendService.snapshot.recordRemoteSendAdmissionCalls, ["fifo-cancel-first"])
    }

    func testExecuteInBackground_failedFirstSendReleasesSecondWithoutRetransmitting() async throws {
        let sendService = MockComposeSendService()
        let firstGate = TransmissionTestGate()
        sendService.postAdmissionGatesByBody = ["first": firstGate]
        sendService.sendNewErrorsByBody = ["first": GmailSendService.SendError.apiError("rejected")]
        let sequencer = OutboundConversationSendSequencer()
        let conversation = ConversationReference(
            persistentStoreURI: URL(string: "x-coredata://conversation/fifo-failure")!
        )
        let orchestrator = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: MockIncrementalSyncPerformer()
        )

        let first = orchestrator.executeInBackground(
            input: makeInput(body: "first"),
            attachmentReferences: [],
            optimisticMessageID: "fifo-failure-first",
            sendOrderTurn: sequencer.enqueue(conversation: conversation)
        )
        let second = orchestrator.executeInBackground(
            input: makeInput(body: "second"),
            attachmentReferences: [],
            optimisticMessageID: "fifo-failure-second",
            sendOrderTurn: sequencer.enqueue(conversation: conversation)
        )
        await firstGate.waitUntilEntered()
        await waitUntil { sequencer.suspendedTurnCount == 1 }

        // Revert-check: removing `await sendOrderTurn?.finish()` from both the
        // send worker's `catch` and the operation's trailing cleanup leaves
        // the second send parked behind the failed first one.
        await firstGate.open()
        await first.task.value
        await waitUntil { sendService.snapshot.recordRemoteSendAdmissionCalls.count == 2 }
        guard sendService.snapshot.recordRemoteSendAdmissionCalls.count == 2 else {
            // Unpark the stuck send so a failing run ends instead of hanging.
            second.cancelBeforeTransmission()
            await second.task.value
            return
        }
        try await second.waitForTransmissionAdmission()
        await second.task.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(
            snapshot.recordRemoteSendAdmissionCalls,
            ["fifo-failure-first", "fifo-failure-second"]
        )
        XCTAssertEqual(snapshot.remoteTransmissionCalls, 2, "The failed first send is never retransmitted")
        XCTAssertEqual(snapshot.retainDefinitelyUnsentCalls, 1)
        XCTAssertEqual(snapshot.reconcileRemoteCommittedSendCalls, ["fifo-failure-second"])
    }

    func testExecuteInBackground_retainAsNotSentPreflightFailureRetainsAndResolvesAdmission() async throws {
        let sendService = MockComposeSendService()
        sendService.sendNewPreflightError = GmailSendService.SendError.apiError("token refresh failed")
        var failureIDs: [String] = []
        let operation = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: MockIncrementalSyncPerformer()
        ).executeInBackground(
            input: makeInput(),
            attachmentReferences: [],
            optimisticMessageID: "retain-preflight",
            reconciliationHooks: .init(
                onSuccess: nil,
                onFailure: { failure in failureIDs.append(failure.optimisticMessageID) }
            ),
            preTransmissionFailureDisposition: .retainAsNotSent
        )

        // Revert-check: routing the generic pre-barrier `catch` of
        // `ComposeSendOrchestrator.executeInBackground` straight to
        // `handleDefiniteFailure` rolls back and fails admission here.
        try await operation.waitForTransmissionAdmission()
        await operation.task.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.remoteTransmissionCalls, 0)
        XCTAssertTrue(snapshot.recordRemoteSendAdmissionCalls.isEmpty)
        XCTAssertEqual(snapshot.rollbackBeforeTransmissionCalls, 0)
        XCTAssertEqual(snapshot.retainDefinitelyUnsentCalls, 1)
        XCTAssertEqual(failureIDs, ["retain-preflight"])
    }

    func testExecuteInBackground_retainAsNotSentPreflightCancellationStillRollsBack() async {
        let sendService = MockComposeSendService()
        sendService.sendNewPreflightError = CancellationError()
        let operation = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: MockIncrementalSyncPerformer()
        ).executeInBackground(
            input: makeInput(),
            attachmentReferences: [],
            optimisticMessageID: "retain-preflight-cancel",
            preTransmissionFailureDisposition: .retainAsNotSent
        )
        await operation.task.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.rollbackBeforeTransmissionCalls, 1)
        XCTAssertEqual(snapshot.retainDefinitelyUnsentCalls, 0)
        do {
            try await operation.waitForTransmissionAdmission()
            XCTFail("A pre-barrier cancellation must fail admission")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testExecuteInBackground_sameConversationSecondReplyWaitsForFirstToFinish() async throws {
        let sendService = MockComposeSendService()
        let firstGate = TransmissionTestGate()
        sendService.postAdmissionGatesByBody = ["first reply": firstGate]
        let sequencer = OutboundConversationSendSequencer()
        let conversation = ConversationReference(
            persistentStoreURI: URL(string: "x-coredata://conversation/fifo-reply-order")!
        )
        let metadata = OutboundMessageRequest.ReplyMetadata(
            recipientEmails: ["to@example.com"],
            fromEmail: "me@example.com",
            fromName: "Me",
            subject: "Re: Plans",
            threadId: "plans-thread",
            inReplyTo: "<plans@example.com>",
            references: ["<plans@example.com>"],
            originalMessage: nil
        )
        let orchestrator = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: MockIncrementalSyncPerformer()
        )

        let first = orchestrator.executeInBackground(
            input: makeInput(body: "first reply", replyMetadata: metadata),
            attachmentReferences: [],
            optimisticMessageID: "fifo-reply-first",
            preTransmissionFailureDisposition: .retainAsNotSent,
            sendOrderTurn: sequencer.enqueue(conversation: conversation)
        )
        let second = orchestrator.executeInBackground(
            input: makeInput(body: "second reply", replyMetadata: metadata),
            attachmentReferences: [],
            optimisticMessageID: "fifo-reply-second",
            preTransmissionFailureDisposition: .retainAsNotSent,
            sendOrderTurn: sequencer.enqueue(conversation: conversation)
        )
        await firstGate.waitUntilEntered()
        await waitUntil { sequencer.suspendedTurnCount == 1 }

        // Chat replies take the `sendReply` branch, which has its own wait.
        // Revert-check: deleting `try await sendOrderTurn?.waitUntilFront()`
        // from the `sendReply` branch of `ComposeSendOrchestrator` admits the
        // second reply while the first is still uploading.
        XCTAssertEqual(sendService.snapshot.recordRemoteSendAdmissionCalls, ["fifo-reply-first"])
        XCTAssertEqual(sendService.snapshot.remoteTransmissionCalls, 1)

        await firstGate.open()
        await first.task.value
        try await second.waitForTransmissionAdmission()
        await second.task.value

        XCTAssertEqual(
            sendService.snapshot.recordRemoteSendAdmissionCalls,
            ["fifo-reply-first", "fifo-reply-second"]
        )
        XCTAssertEqual(sendService.snapshot.sendReplyCalls, 2)
        XCTAssertEqual(sendService.snapshot.remoteTransmissionCalls, 2)
    }

    func testExecuteInBackground_rollbackThatRetainsAsNotSentResolvesAdmission() async throws {
        let sendService = MockComposeSendService()
        sendService.sendNewPreflightError = GmailSendService.SendError.apiError("attachment unreadable")
        // The rollback could not write its `ChatReplyDraft`, so it kept the
        // row as "Not sent" instead.
        sendService.rollbackOutcome = .retainedAsNotSent
        let operation = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: MockIncrementalSyncPerformer()
        ).executeInBackground(
            input: makeInput(),
            attachmentReferences: [],
            optimisticMessageID: "rollback-retained"
        )

        // Revert-check: making `handleDefiniteFailure` fail admission
        // regardless of `PreTransmissionRollbackOutcome` throws here, and the
        // chat composer would restore the text the bubble still shows.
        try await operation.waitForTransmissionAdmission()
        await operation.task.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.rollbackBeforeTransmissionCalls, 1)
        XCTAssertEqual(snapshot.remoteTransmissionCalls, 0)
        XCTAssertTrue(snapshot.recordRemoteSendAdmissionCalls.isEmpty)
        XCTAssertNotNil(snapshot.failureReasons["rollback-retained"])
    }

    // MARK: - Pre-barrier connectivity wait

    func testExecuteInBackground_satisfiedPath_proceedsWithoutStartingDeadline() async throws {
        let sendService = MockComposeSendService()
        let pathMonitor = OutboundNetworkPathMonitor(manualPathSatisfied: true)
        let clock = FakeSyncClock()
        let operation = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: MockIncrementalSyncPerformer(),
            networkPathMonitor: pathMonitor,
            connectivityWaitClock: clock
        ).executeInBackground(input: makeInput(), attachmentReferences: [], optimisticMessageID: "path-satisfied")

        try await operation.waitForTransmissionAdmission()
        await operation.task.value

        XCTAssertEqual(sendService.snapshot.remoteTransmissionCalls, 1)
        XCTAssertTrue(clock.sleeps.isEmpty, "A satisfied path never starts the deadline")
    }

    func testExecuteInBackground_knownOfflinePath_waitsBeforeTransmittingUntilPathReturns() async throws {
        let sendService = MockComposeSendService()
        let pathMonitor = OutboundNetworkPathMonitor(manualPathSatisfied: false)
        let clock = ParkedSyncClock()
        let operation = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: MockIncrementalSyncPerformer(),
            networkPathMonitor: pathMonitor,
            connectivityWaitClock: clock
        ).executeInBackground(
            input: makeInput(),
            attachmentReferences: [],
            optimisticMessageID: "path-returns",
            preTransmissionFailureDisposition: .retainAsNotSent
        )
        await waitUntil { pathMonitor.suspendedWaiterCount == 1 }

        // Revert-check: deleting the `OutboundConnectivityGate.waitForUsablePath`
        // call from `ComposeSendOrchestrator.executeInBackground`'s `transmit`
        // sends at once into the outage (the fail-fast session's -1009 then
        // ends it as "Not sent"), so nothing is ever suspended here.
        XCTAssertEqual(sendService.snapshot.sendNewCalls, 0)
        XCTAssertEqual(sendService.snapshot.remoteTransmissionCalls, 0)
        XCTAssertTrue(sendService.snapshot.recordRemoteSendAdmissionCalls.isEmpty)
        XCTAssertEqual(
            clock.sleeps,
            [UInt64(NetworkConfig.sendConnectivityWaitTimeout * 1_000_000_000)]
        )

        // The handoff completes: the send goes out by itself.
        pathMonitor.pathDidChange(isSatisfied: true)
        try await operation.waitForTransmissionAdmission()
        await operation.task.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.recordRemoteSendAdmissionCalls, ["path-returns"])
        XCTAssertEqual(snapshot.remoteTransmissionCalls, 1)
        XCTAssertEqual(snapshot.recordRemoteCommittedSendCalls, ["path-returns"])
        XCTAssertEqual(snapshot.retainDefinitelyUnsentCalls, 0)
        XCTAssertEqual(snapshot.rollbackBeforeTransmissionCalls, 0)
    }

    func testExecuteInBackground_pathDownPastDeadline_chatReplyRetainsAsNotSentWithoutTransmitting() async throws {
        let sendService = MockComposeSendService()
        let pathMonitor = OutboundNetworkPathMonitor(manualPathSatisfied: false)
        // Fires the deadline at once.
        let clock = FakeSyncClock()
        var failureIDs: [String] = []
        let operation = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: MockIncrementalSyncPerformer(),
            networkPathMonitor: pathMonitor,
            connectivityWaitClock: clock
        ).executeInBackground(
            input: makeInput(),
            attachmentReferences: [],
            optimisticMessageID: "path-deadline-reply",
            reconciliationHooks: .init(
                onSuccess: nil,
                onFailure: { failure in failureIDs.append(failure.optimisticMessageID) }
            ),
            preTransmissionFailureDisposition: .retainAsNotSent
        )

        // Revert-check: making `OutboundConnectivityGate.waitForUsablePath`
        // throw `CancellationError` at the deadline (instead of the
        // pre-transmission -1009) rolls the reply back and fails admission
        // here; deleting its call transmits.
        try await operation.waitForTransmissionAdmission()
        await operation.task.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.sendNewCalls, 0, "Preflight never started")
        XCTAssertEqual(snapshot.remoteTransmissionCalls, 0)
        XCTAssertTrue(snapshot.recordRemoteSendAdmissionCalls.isEmpty)
        XCTAssertTrue(snapshot.recordAmbiguousRemoteSendCalls.isEmpty)
        XCTAssertEqual(snapshot.retainDefinitelyUnsentCalls, 1)
        XCTAssertEqual(snapshot.rollbackBeforeTransmissionCalls, 0)
        XCTAssertEqual(
            snapshot.failureReasons["path-deadline-reply"],
            URLError(.notConnectedToInternet).localizedDescription
        )
        XCTAssertEqual(failureIDs, ["path-deadline-reply"])
        XCTAssertEqual(
            clock.sleeps,
            [UInt64(NetworkConfig.sendConnectivityWaitTimeout * 1_000_000_000)]
        )
    }

    func testExecuteInBackground_pathDownPastDeadline_composeRollsBackToComposer() async {
        let sendService = MockComposeSendService()
        let pathMonitor = OutboundNetworkPathMonitor(manualPathSatisfied: false)
        let operation = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: MockIncrementalSyncPerformer(),
            networkPathMonitor: pathMonitor,
            connectivityWaitClock: FakeSyncClock()
        ).executeInBackground(input: makeInput(), attachmentReferences: [], optimisticMessageID: "path-deadline-compose")

        // Revert-check: deleting the `OutboundConnectivityGate.waitForUsablePath`
        // call from `transmit` admits and transmits this send.
        do {
            try await operation.waitForTransmissionAdmission()
            XCTFail("An offline compose must hand its content back to the composer")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await operation.task.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.remoteTransmissionCalls, 0)
        XCTAssertTrue(snapshot.recordRemoteSendAdmissionCalls.isEmpty)
        XCTAssertEqual(snapshot.rollbackBeforeTransmissionCalls, 1)
        XCTAssertEqual(snapshot.retainDefinitelyUnsentCalls, 0)
    }

    func testExecuteInBackground_cancelWhileWaitingForPath_rollsBackWithoutWaitingOutDeadline() async {
        let sendService = MockComposeSendService()
        let pathMonitor = OutboundNetworkPathMonitor(manualPathSatisfied: false)
        let operation = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: MockIncrementalSyncPerformer(),
            networkPathMonitor: pathMonitor,
            connectivityWaitClock: ParkedSyncClock()
        ).executeInBackground(
            input: makeInput(),
            attachmentReferences: [],
            optimisticMessageID: "path-cancelled",
            preTransmissionFailureDisposition: .retainAsNotSent
        )
        await waitUntil { pathMonitor.suspendedWaiterCount == 1 }
        var finished = false
        let watcher = Task { @MainActor in
            await operation.task.value
            finished = true
        }

        // What `OutboundTaskRegistry.closeAdmission` invokes for a preflight
        // entry. Neither the path nor the deadline ever fires here.
        // Revert-check: dropping the `onCancel` handler from
        // `OutboundNetworkPathMonitor.waitUntilPathSatisfied` leaves the send
        // parked on the path, and this wait times out.
        operation.cancelBeforeTransmission()
        await waitUntil { finished }
        if !finished {
            // Unpark the stuck send so a failing run ends instead of hanging.
            pathMonitor.pathDidChange(isSatisfied: true)
        }
        await watcher.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.remoteTransmissionCalls, 0)
        // Teardown rolls back even a `.retainAsNotSent` send.
        XCTAssertEqual(snapshot.rollbackBeforeTransmissionCalls, 1)
        XCTAssertEqual(snapshot.retainDefinitelyUnsentCalls, 0)
        XCTAssertEqual(pathMonitor.suspendedWaiterCount, 0)
        do {
            try await operation.waitForTransmissionAdmission()
            XCTFail("A cancelled waiting send must not be admitted")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testExecuteInBackground_queuedSendsWaitForPathConcurrentlyThenTransmitInOrder() async throws {
        let sendService = MockComposeSendService()
        let pathMonitor = OutboundNetworkPathMonitor(manualPathSatisfied: false)
        let clock = ParkedSyncClock()
        let sequencer = OutboundConversationSendSequencer()
        let conversation = ConversationReference(
            persistentStoreURI: URL(string: "x-coredata://conversation/path-fifo")!
        )
        let orchestrator = ComposeSendOrchestrator(
            sendService: sendService,
            syncPerformer: MockIncrementalSyncPerformer(),
            networkPathMonitor: pathMonitor,
            connectivityWaitClock: clock
        )

        let first = orchestrator.executeInBackground(
            input: makeInput(body: "first"),
            attachmentReferences: [],
            optimisticMessageID: "path-fifo-first",
            preTransmissionFailureDisposition: .retainAsNotSent,
            sendOrderTurn: sequencer.enqueue(conversation: conversation)
        )
        let second = orchestrator.executeInBackground(
            input: makeInput(body: "second"),
            attachmentReferences: [],
            optimisticMessageID: "path-fifo-second",
            preTransmissionFailureDisposition: .retainAsNotSent,
            sendOrderTurn: sequencer.enqueue(conversation: conversation)
        )

        // Both sends wait on the path at once, each on its own deadline,
        // rather than the second waiting in the FIFO for the first's wait.
        // Revert-check: moving the `OutboundConnectivityGate.waitForUsablePath`
        // call after `sendOrderTurn?.waitUntilFront()` parks the second send
        // in the sequencer instead, and only one path waiter ever appears.
        await waitUntil { pathMonitor.suspendedWaiterCount == 2 }
        XCTAssertEqual(sequencer.suspendedTurnCount, 0)
        XCTAssertEqual(clock.sleeps.count, 2)
        XCTAssertEqual(sendService.snapshot.remoteTransmissionCalls, 0)

        pathMonitor.pathDidChange(isSatisfied: true)
        try await first.waitForTransmissionAdmission()
        try await second.waitForTransmissionAdmission()
        await first.task.value
        await second.task.value

        XCTAssertEqual(
            sendService.snapshot.recordRemoteSendAdmissionCalls,
            ["path-fifo-first", "path-fifo-second"]
        )
        XCTAssertEqual(sendService.snapshot.remoteTransmissionCalls, 2)
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
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
private final class MockOutboundBackgroundTaskManager: OutboundBackgroundTaskManaging {
    var identifier = UIBackgroundTaskIdentifier(rawValue: 42)
    var expiresDuringBegin = false
    var onEnd: (() -> Void)?
    private(set) var beginCalls = 0
    private(set) var endedIdentifiers: [UIBackgroundTaskIdentifier] = []
    private var expirationHandler: (@MainActor @Sendable () -> Void)?

    func begin(expirationHandler: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier {
        beginCalls += 1
        self.expirationHandler = expirationHandler
        if expiresDuringBegin { expirationHandler() }
        return identifier
    }

    func end(_ identifier: UIBackgroundTaskIdentifier) {
        endedIdentifiers.append(identifier)
        onEnd?()
    }

    func expire() {
        expirationHandler?()
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
        let lastReplyOriginalHTML: String?
        let lastReplyHadDeferredOriginalHTML: Bool
        let failureReasons: [String: String]
    }

    private let queue = DispatchQueue(label: "ComposeSendOrchestratorTests.MockComposeSendService")

    var sendDelayNanoseconds: UInt64 = 0
    var sendNewPreflightError: Error?
    var sendNewError: Error?
    /// Holds `sendNew` / `sendReply` for these bodies after admission (an
    /// upload in flight).
    var postAdmissionGatesByBody: [String: TransmissionTestGate] = [:]
    /// Definite post-admission rejections for these bodies.
    var sendNewErrorsByBody: [String: Error] = [:]
    var sendReplyError: Error?
    var recordRemoteSendAdmissionError: Error?
    var recordAmbiguousRemoteSendError: Error?
    var reconcileRemoteCommittedSendError: Error?
    /// What the rollback reports; `.retainedAsNotSent` stands in for a
    /// rollback whose `ChatReplyDraft` write failed.
    var rollbackOutcome: PreTransmissionRollbackOutcome = .rolledBack

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
    private var _lastReplyOriginalHTML: String?
    private var _lastReplyHadDeferredOriginalHTML = false
    private var _failureReasons: [String: String] = [:]

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
                failedAttachmentReferences: _failedAttachmentReferences,
                lastReplyOriginalHTML: _lastReplyOriginalHTML,
                lastReplyHadDeferredOriginalHTML: _lastReplyHadDeferredOriginalHTML,
                failureReasons: _failureReasons
            )
        }
    }

    @MainActor
    func recordSendFailureReason(optimisticMessageID: String, reason: String) {
        queue.sync { _failureReasons[optimisticMessageID] = reason }
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
        queue.sync {
            _sendReplyCalls += 1
            _lastReplyOriginalHTML = originalMessage?.originalHTML
            _lastReplyHadDeferredOriginalHTML = originalMessage?.deferredOriginalHTML != nil
        }

        try await beforeTransmission()
        queue.sync { _remoteTransmissionCalls += 1 }

        if let gate = postAdmissionGatesByBody[body] {
            await gate.enterAndWait()
        }
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

        if let gate = postAdmissionGatesByBody[body] {
            await gate.enterAndWait()
        }
        if sendDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: sendDelayNanoseconds)
        }
        if let sendNewError {
            throw sendNewError
        }
        if let error = sendNewErrorsByBody[body] {
            throw error
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
    ) -> PreTransmissionRollbackOutcome {
        queue.sync {
            _rollbackBeforeTransmissionCalls += 1
            _failedAttachmentReferences = fallbackAttachmentReferences
        }
        return rollbackOutcome
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

/// Parks one send after admission until the test opens it.
private actor TransmissionTestGate {
    private var entered = false
    private var isOpen = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final class ReplyResolutionProbe: @unchecked Sendable {
    struct Snapshot {
        let messageIDs: [String]
        let mainThreadObservations: [Bool]
    }

    private let lock = NSLock()
    private let result: String?
    private var messageIDs: [String] = []
    private var mainThreadObservations: [Bool] = []

    init(result: String?) {
        self.result = result
    }

    var snapshot: Snapshot {
        lock.withLock {
            Snapshot(
                messageIDs: messageIDs,
                mainThreadObservations: mainThreadObservations
            )
        }
    }

    func load(_ source: ReplyQuotedHTMLSource) -> String? {
        lock.withLock {
            messageIDs.append(source.messageId)
            mainThreadObservations.append(Thread.isMainThread)
            return result
        }
    }
}
