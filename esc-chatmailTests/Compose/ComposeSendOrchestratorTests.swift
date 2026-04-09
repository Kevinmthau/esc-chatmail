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
            attachmentObjectURIs: [],
            optimisticMessageID: "optimistic-1"
        )
        await task.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.markUploadedCalls, 1)
        XCTAssertEqual(snapshot.sendNewCalls, 1)
        XCTAssertEqual(snapshot.sendReplyCalls, 0)
        XCTAssertEqual(snapshot.markFailedCalls, 0)
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 1)
    }

    func testExecuteInBackground_reply_runsSendReplyAndSync() async {
        let sendService = MockComposeSendService()
        let syncPerformer = MockIncrementalSyncPerformer()
        let orchestrator = ComposeSendOrchestrator(sendService: sendService, syncPerformer: syncPerformer)

        let replyMetadata = OutboundMessageRequest.ReplyMetadata(
            recipientEmails: ["to@example.com"],
            subject: "Re: Hello",
            threadId: "thread-1",
            inReplyTo: "<id-1>",
            references: ["<id-1>"],
            originalMessage: nil
        )

        let task = orchestrator.executeInBackground(
            input: makeInput(body: "reply body", replyMetadata: replyMetadata),
            attachmentObjectURIs: [],
            optimisticMessageID: "optimistic-2"
        )
        await task.value

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
            subject: nil,
            threadId: "thread-1",
            inReplyTo: "<id-1>",
            references: ["<id-1>"],
            originalMessage: nil
        )

        let task = orchestrator.executeInBackground(
            input: makeInput(body: "reply body", replyMetadata: replyMetadata),
            attachmentObjectURIs: [],
            optimisticMessageID: "optimistic-2b"
        )
        await task.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.sendNewCalls, 0)
        XCTAssertEqual(snapshot.sendReplyCalls, 1)
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 1)
    }

    func testExecuteInBackground_cancelled_doesNotTriggerSync() async {
        let sendService = MockComposeSendService()
        sendService.sendDelayNanoseconds = 500_000_000

        let syncPerformer = MockIncrementalSyncPerformer()
        let orchestrator = ComposeSendOrchestrator(sendService: sendService, syncPerformer: syncPerformer)

        let task = orchestrator.executeInBackground(
            input: makeInput(),
            attachmentObjectURIs: [],
            optimisticMessageID: "optimistic-3"
        )

        task.cancel()
        await task.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.sendNewCalls, 1)
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 0)
    }

    func testExecuteInBackground_sendFailure_usesUnifiedOptimisticCleanup() async {
        let sendService = MockComposeSendService()
        sendService.sendNewError = GmailSendService.SendError.apiError("boom")

        let syncPerformer = MockIncrementalSyncPerformer()
        let orchestrator = ComposeSendOrchestrator(sendService: sendService, syncPerformer: syncPerformer)

        let task = orchestrator.executeInBackground(
            input: makeInput(),
            attachmentObjectURIs: [],
            optimisticMessageID: "optimistic-failure"
        )
        await task.value

        let snapshot = sendService.snapshot
        XCTAssertEqual(snapshot.sendNewCalls, 1)
        XCTAssertEqual(snapshot.handleFailedCalls, 1)
        XCTAssertEqual(snapshot.markFailedCalls, 0)
        XCTAssertEqual(syncPerformer.performIncrementalSyncCalls, 0)
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
        let updateOptimisticCalls: Int
        let markFailedCalls: Int
        let handleFailedCalls: Int
    }

    private let queue = DispatchQueue(label: "ComposeSendOrchestratorTests.MockComposeSendService")

    var sendDelayNanoseconds: UInt64 = 0
    var sendNewError: Error?
    var sendReplyError: Error?

    private var _markUploadedCalls = 0
    private var _sendNewCalls = 0
    private var _sendReplyCalls = 0
    private var _updateOptimisticCalls = 0
    private var _markFailedCalls = 0
    private var _handleFailedCalls = 0

    var snapshot: Snapshot {
        queue.sync {
            Snapshot(
                markUploadedCalls: _markUploadedCalls,
                sendNewCalls: _sendNewCalls,
                sendReplyCalls: _sendReplyCalls,
                updateOptimisticCalls: _updateOptimisticCalls,
                markFailedCalls: _markFailedCalls,
                handleFailedCalls: _handleFailedCalls
            )
        }
    }

    @MainActor
    func markAttachmentsAsUploaded(objectURIs: [String]) {
        queue.sync { _markUploadedCalls += 1 }
    }

    func sendReply(
        to recipients: [String],
        body: String,
        subject: String,
        threadId: String,
        inReplyTo: String?,
        references: [String],
        originalMessage: QuotedMessage?,
        attachmentInfos: [GmailSendService.AttachmentInfo]
    ) async throws -> GmailSendService.SendResult {
        queue.sync { _sendReplyCalls += 1 }

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
        inlineAttachmentInfos: [GmailSendService.AttachmentInfo]
    ) async throws -> GmailSendService.SendResult {
        queue.sync { _sendNewCalls += 1 }

        if sendDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: sendDelayNanoseconds)
        }
        if let sendNewError {
            throw sendNewError
        }
        return GmailSendService.SendResult(messageId: "sent-id", threadId: "thread-id")
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
    func handleFailedOptimisticMessage(byID messageID: String, fallbackAttachmentObjectURIs: [String]) {
        queue.sync { _handleFailedCalls += 1 }
    }
}
