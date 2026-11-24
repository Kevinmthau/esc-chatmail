import XCTest
@testable import esc_chatmail

/// A cancelled run (an expired background task, an account transition) stops
/// deriving a message's text and records no verdict for it: the derivation
/// steps cannot be interrupted, so the run is answered between them.
final class MessageDerivationCancellationTests: XCTestCase {

    /// Revert-check: the `Task.checkCancellation()` calls between the steps of
    /// `MessageProcessor.processGmailMessage` (without them a cancelled run
    /// derives everything and returns the message).
    /// HONEST SCOPE: the task is cancelled before the processor starts, so any
    /// one of those checks makes this pass; a revert has to take all of them.
    func testProcessGmailMessage_cancelledRun_throwsCancellationError() async {
        let message = GmailMessageBuilder()
            .withId("cancelled")
            .withBodyHtml("<div>Hello there</div>")
            .build()
        let task = Task { () -> ProcessedMessage? in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MessageProcessor().processGmailMessage(message, myAliases: [])
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled run must not return a derived message")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    /// The rich-content pre-run is one more cleanup of the whole body; a run
    /// cancelled while the processor ran stops ahead of it, with no verdict.
    /// Revert-check: the `Task.checkCancellation()` ahead of
    /// `MessagePersister.richContentPrerun` in `prepareMessage` (the message is
    /// then prepared, pre-run and all).
    func testPrepareMessage_cancelledDuringProcessing_throwsBeforeThePrerun() async {
        var processed = ProcessedMessage()
        processed.id = "cancelled-prerun"
        processed.htmlBody = "<div>Hello there</div>"
        let persister = MessagePersister(
            messageProcessor: CancellingMessageProcessor(processedMessage: processed),
            photoPrefetcher: { _ in },
            inlineCIDPrefetchScheduler: { _, _ in }
        )
        let message = GmailMessageBuilder().withId("cancelled-prerun").withBodyHtml("<div>Hello there</div>").build()
        do {
            let prepared = try await persister.prepareMessage(message, myAliases: [])
            XCTFail("A cancelled run must not prepare the message: \(prepared)")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }
}

/// Cancels the task it runs in, as an expiring background task does, and
/// returns its message.
private final class CancellingMessageProcessor: MessageProcessor, @unchecked Sendable {
    private let processedMessage: ProcessedMessage

    init(processedMessage: ProcessedMessage) {
        self.processedMessage = processedMessage
    }

    override func processGmailMessage(
        _ gmailMessage: GmailMessage,
        myAliases: Set<String>,
        sendAsAliases: [SendAsAlias] = []
    ) async throws -> ProcessedMessage? {
        withUnsafeCurrentTask { $0?.cancel() }
        return processedMessage
    }
}

/// At most one message with an oversized text body is prepared at a time, and
/// the batch's results keep its order.
final class OversizedPreparationTests: XCTestCase {

    // Revert-check: the `oversizedIndexInFlight` guard in
    // `MessagePersister.prepareMessagesConcurrently` (oversized messages then
    // overlap like any others).
    func testOversizedMessages_arePreparedOneAtATime_inOrder() async throws {
        let processor = OverlapRecordingProcessor()
        let persister = MessagePersister(
            messageProcessor: processor,
            photoPrefetcher: { _ in },
            inlineCIDPrefetchScheduler: { _, _ in }
        )
        let oversized = SyncConfig.oversizedPreparationBodyBytes + 1
        let sizes = [10, oversized, oversized, 10, oversized, 10, 10, oversized, 10, 10]
        let messages = sizes.enumerated().map { index, size in
            Self.message(id: "m\(index)", textBodyBytes: size)
        }

        let prepared = try await persister.prepareMessagesConcurrently(messages, myAliases: [])

        XCTAssertEqual(prepared.count, messages.count)
        for (index, outcome) in prepared.enumerated() {
            guard case .processed(let message) = outcome else {
                return XCTFail("\(index): \(outcome)")
            }
            XCTAssertEqual(message.id, "m\(index)")
        }
        XCTAssertEqual(processor.maximumOversizedOverlap, 1)
        XCTAssertGreaterThan(processor.maximumOverlap, 1, "Ordinary messages still overlap")
    }

    func testTextBodyByteCount_countsTextPartsOnly() {
        let message = GmailMessage(
            id: "parts",
            threadId: nil,
            labelIds: nil,
            snippet: nil,
            historyId: nil,
            internalDate: nil,
            payload: MessagePart(
                partId: "",
                mimeType: "multipart/mixed",
                filename: nil,
                headers: nil,
                body: MessageBody(size: 0, data: nil, attachmentId: nil),
                parts: [
                    Self.part(mimeType: "text/plain", size: 100),
                    Self.part(mimeType: "text/html; charset=utf-8", size: 200),
                    Self.part(mimeType: "text/plain", size: 5_000, filename: "notes.txt"),
                    Self.part(mimeType: "image/png", size: 7_000),
                ]
            ),
            sizeEstimate: 12_300
        )
        XCTAssertEqual(MessagePersister.textBodyByteCount(of: message), 300)
    }

    private static func part(mimeType: String, size: Int, filename: String? = nil) -> MessagePart {
        MessagePart(
            partId: "1",
            mimeType: mimeType,
            filename: filename,
            headers: nil,
            body: MessageBody(size: size, data: nil, attachmentId: "a"),
            parts: nil
        )
    }

    private static func message(id: String, textBodyBytes: Int) -> GmailMessage {
        GmailMessage(
            id: id,
            threadId: "t-\(id)",
            labelIds: ["INBOX"],
            snippet: nil,
            historyId: "1",
            internalDate: "1704067200000",
            payload: MessagePart(
                partId: "",
                mimeType: "text/html",
                filename: nil,
                headers: [MessageHeader(name: "From", value: "a@example.com")],
                body: MessageBody(size: textBodyBytes, data: nil, attachmentId: "body-\(id)"),
                parts: nil
            ),
            sizeEstimate: textBodyBytes
        )
    }
}

/// Holds each message for a moment and records how many it held at once.
private final class OverlapRecordingProcessor: MessageProcessor, @unchecked Sendable {
    /// `@unchecked Sendable`: every read and write of the counts is under `lock`.
    private let lock = NSLock()
    private var running = 0
    private var oversizedRunning = 0
    private var maxRunning = 0
    private var maxOversizedRunning = 0

    var maximumOverlap: Int { lock.withLock { maxRunning } }
    var maximumOversizedOverlap: Int { lock.withLock { maxOversizedRunning } }

    override func processGmailMessage(
        _ gmailMessage: GmailMessage,
        myAliases: Set<String>,
        sendAsAliases: [SendAsAlias] = []
    ) async throws -> ProcessedMessage? {
        let isOversized = MessagePersister.textBodyByteCount(of: gmailMessage) > SyncConfig.oversizedPreparationBodyBytes
        lock.withLock {
            running += 1
            maxRunning = max(maxRunning, running)
            if isOversized {
                oversizedRunning += 1
                maxOversizedRunning = max(maxOversizedRunning, oversizedRunning)
            }
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        lock.withLock {
            running -= 1
            if isOversized { oversizedRunning -= 1 }
        }
        var processed = ProcessedMessage()
        processed.id = gmailMessage.id
        return processed
    }
}
