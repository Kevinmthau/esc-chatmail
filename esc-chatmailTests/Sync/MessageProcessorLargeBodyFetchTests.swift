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
}
