import XCTest
@testable import esc_chatmail

/// Pins the error contract of large-body fetches (Gmail returns body parts
/// larger than ~25KB by attachmentId): a 404 keeps the message processable
/// without the part, while every other failure throws so callers block the
/// cursor instead of persisting a silently empty body and counting it as a
/// truthful persistence success.
final class MessageProcessorLargeBodyFetchTests: XCTestCase {

    private func makeLargeBodyMessage(id: String = "m-large") -> GmailMessage {
        GmailMessage(
            id: id,
            threadId: "t-\(id)",
            labelIds: ["INBOX"],
            snippet: "Snippet \(id)",
            historyId: nil,
            internalDate: "1700000000000",
            payload: MessagePart(
                partId: "",
                mimeType: "text/plain",
                filename: nil,
                headers: [
                    MessageHeader(name: "From", value: "Alice Smith <alice@example.com>"),
                    MessageHeader(name: "To", value: "me@example.com"),
                    MessageHeader(name: "Subject", value: "Large body"),
                    MessageHeader(name: "Content-Type", value: "text/plain; charset=UTF-8")
                ],
                body: MessageBody(size: 30_000, data: nil, attachmentId: "att-\(id)"),
                parts: nil
            ),
            sizeEstimate: 30_000
        )
    }

    func testFetchedLargeBodyBecomesPlainTextBody() async throws {
        let body = "The complete large plain-text body"
        let processor = MessageProcessor(fetchAttachmentData: { _, _ in Data(body.utf8) })

        let processed = try await processor.processGmailMessage(makeLargeBodyMessage(), myAliases: [])

        XCTAssertEqual(processed?.plainTextBody, body)
    }

    func testRateLimitedLargeBodyFetchThrows() async {
        let processor = MessageProcessor(fetchAttachmentData: { _, _ in
            throw APIError.rateLimited(retryAfter: 12)
        })

        do {
            _ = try await processor.processGmailMessage(makeLargeBodyMessage(), myAliases: [])
            XCTFail("A rate-limited body fetch must throw, not yield an empty body")
        } catch let error as APIError {
            guard case .rateLimited = error else {
                return XCTFail("Expected rateLimited, got \(error)")
            }
        } catch {
            XCTFail("Expected APIError.rateLimited, got \(error)")
        }
    }

    func testQuotaExhaustedLargeBodyFetchThrows() async {
        let processor = MessageProcessor(fetchAttachmentData: { _, _ in
            throw APIError.quotaExhausted("Daily Limit Exceeded")
        })

        do {
            _ = try await processor.processGmailMessage(makeLargeBodyMessage(), myAliases: [])
            XCTFail("A quota-exhausted body fetch must throw so the run can abort")
        } catch let error as APIError {
            guard case .quotaExhausted = error else {
                return XCTFail("Expected quotaExhausted, got \(error)")
            }
        } catch {
            XCTFail("Expected APIError.quotaExhausted, got \(error)")
        }
    }

    func testMissingAttachmentKeepsMessageProcessableWithoutBody() async throws {
        let processor = MessageProcessor(fetchAttachmentData: { _, _ in
            throw APIError.notFound("attachment")
        })

        let processed = try await processor.processGmailMessage(makeLargeBodyMessage(), myAliases: [])

        XCTAssertNotNil(processed, "A 404'd attachment is gone for good; the message itself must still process")
        XCTAssertNil(processed?.plainTextBody)
        XCTAssertNil(processed?.htmlBody)
    }

    func testUndecodableAttachmentResponsePersistsWithoutBody() async throws {
        let processor = MessageProcessor(fetchAttachmentData: { _, _ in
            throw APIError.invalidData("Failed to decode attachment data from base64")
        })

        let processed = try await processor.processGmailMessage(makeLargeBodyMessage(), myAliases: [])

        XCTAssertNotNil(
            processed,
            "An undecodable response repeats on every fetch; blocking could only end in abandonment"
        )
        XCTAssertNil(processed?.plainTextBody)
        XCTAssertNil(processed?.htmlBody)
    }

    // MARK: - Salvage probe (embedded-HTML sweep)

    func testSalvageProbeFailureAfterSuccessfulBodyFetchKeepsMessage() async throws {
        let body = "The complete large plain-text body"
        // First fetch (main extraction) succeeds; the salvage sweep's re-fetch
        // of the same attachment is rate limited.
        let script = FetchScript([
            .success(Data(body.utf8)),
            .failure(APIError.rateLimited(retryAfter: 7)),
        ])
        let processor = MessageProcessor(fetchAttachmentData: { _, _ in try script.next() })

        let processed = try await processor.processGmailMessage(makeLargeBodyMessage(), myAliases: [])

        XCTAssertEqual(
            processed?.plainTextBody, body,
            "A failed best-effort HTML probe must not discard the successfully fetched body"
        )
    }

    func testQuotaDuringSalvageProbeStillAborts() async {
        let script = FetchScript([
            .success(Data("large body".utf8)),
            .failure(APIError.quotaExhausted("Daily Limit Exceeded")),
        ])
        let processor = MessageProcessor(fetchAttachmentData: { _, _ in try script.next() })

        do {
            _ = try await processor.processGmailMessage(makeLargeBodyMessage(), myAliases: [])
            XCTFail("Quota exhaustion is account-scoped and must abort even from the salvage probe")
        } catch let error as APIError {
            guard case .quotaExhausted = error else {
                return XCTFail("Expected quotaExhausted, got \(error)")
            }
        } catch {
            XCTFail("Expected APIError.quotaExhausted, got \(error)")
        }
    }

    func testSalvageSweepDoesNotDownloadFileAttachments() async throws {
        let inlineText = "Please see the attached report."
        let script = FetchScript([])
        let processor = MessageProcessor(fetchAttachmentData: { _, _ in try script.next() })

        let message = GmailMessage(
            id: "m-with-pdf",
            threadId: "t-with-pdf",
            labelIds: ["INBOX"],
            snippet: "Snippet",
            historyId: nil,
            internalDate: "1700000000000",
            payload: MessagePart(
                partId: "",
                mimeType: "multipart/mixed",
                filename: nil,
                headers: [
                    MessageHeader(name: "From", value: "Alice Smith <alice@example.com>"),
                    MessageHeader(name: "To", value: "me@example.com"),
                    MessageHeader(name: "Subject", value: "Report attached")
                ],
                body: nil,
                parts: [
                    MessagePart(
                        partId: "0",
                        mimeType: "text/plain",
                        filename: nil,
                        headers: [MessageHeader(name: "Content-Type", value: "text/plain; charset=UTF-8")],
                        body: MessageBody(
                            size: inlineText.count,
                            data: Data(inlineText.utf8).base64EncodedString(),
                            attachmentId: nil
                        ),
                        parts: nil
                    ),
                    MessagePart(
                        partId: "1",
                        mimeType: "application/pdf",
                        filename: "report.pdf",
                        headers: [
                            MessageHeader(name: "Content-Type", value: "application/pdf"),
                            MessageHeader(name: "Content-Disposition", value: "attachment; filename=\"report.pdf\"")
                        ],
                        body: MessageBody(size: 20_000_000, data: nil, attachmentId: "att-pdf"),
                        parts: nil
                    )
                ]
            ),
            sizeEstimate: 20_000_000
        )

        let processed = try await processor.processGmailMessage(message, myAliases: [])

        XCTAssertEqual(processed?.plainTextBody, inlineText)
        XCTAssertEqual(
            script.recordedCallCount, 0,
            "The embedded-HTML sweep must never download file attachments as body candidates"
        )
    }
}

/// Scripted attachment-fetch results, consumed in call order. Throws
/// `unexpectedCall` when invoked more times than scripted.
private final class FetchScript: @unchecked Sendable {
    struct UnexpectedCall: Error {}

    private let lock = NSLock()
    private var results: [Result<Data, Error>]
    private var callCount = 0

    init(_ results: [Result<Data, Error>]) {
        self.results = results
    }

    func next() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        guard !results.isEmpty else { throw UnexpectedCall() }
        return try results.removeFirst().get()
    }

    var recordedCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }
}
