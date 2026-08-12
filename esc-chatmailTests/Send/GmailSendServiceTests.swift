import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class GmailSendServiceTests: XCTestCase {
    private var coreDataStack: TestCoreDataStack!
    private var apiClient: MockGmailAPIClient!
    private var authSession: AuthSession!
    private var sendService: GmailSendService!

    override func setUp() {
        super.setUp()
        coreDataStack = TestCoreDataStack()
        apiClient = MockGmailAPIClient()
        authSession = AuthSession()
        authSession.userEmail = "sender@example.com"
        authSession.userName = "Sender"
        sendService = GmailSendService(
            viewContext: coreDataStack.viewContext,
            apiClient: apiClient,
            authSession: authSession
        )
    }

    override func tearDown() {
        sendService = nil
        authSession = nil
        apiClient = nil
        coreDataStack = nil
        super.tearDown()
    }

    func testSendNew_usesInjectedGmailAPIClient() async throws {
        apiClient.sendMessageResponse = SendMessageResponse(id: "sent-id", threadId: "thread-id")

        let result = try await sendService.sendNew(
            to: ["to@example.com"],
            body: "Hello world",
            subject: "Subject"
        )

        XCTAssertEqual(result.messageId, "sent-id")
        XCTAssertEqual(result.threadId, "thread-id")
        XCTAssertEqual(apiClient.sendMessageCallCount, 1)
        XCTAssertEqual(apiClient.sendMessageCalls.first?.threadId, nil)
        XCTAssertFalse(apiClient.sendMessageCalls.first?.rawMessage.isEmpty ?? true)
    }

    func testSendNew_carriesProvidedReconciliationMessageIDInMIME() async throws {
        let messageID = MimeBuilder.messageId(
            forOptimisticMessageID: "optimistic-message-id"
        )

        _ = try await sendService.sendNew(
            to: ["to@example.com"],
            body: "Hello world",
            subject: "Subject",
            messageId: messageID
        )

        let rawMessage = try XCTUnwrap(
            apiClient.sendMessageCalls.first?.rawMessage
        )
        let mimeData = try XCTUnwrap(Data(base64UrlEncoded: rawMessage))
        let mime = try XCTUnwrap(String(data: mimeData, encoding: .utf8))
        XCTAssertTrue(mime.contains("Message-ID: \(messageID)\r\n"))
    }

    func testSendNew_messageIDHeaderInjection_isCollapsedIntoSingleHeader() async throws {
        // Revert-check: MimeBuilder.sanitizeHeaderValue applied to the Message-ID value in
        // MimeBuilder.buildSimpleMessage. Without that call the raw CRLF reaches the MIME and
        // the injected "Bcc:" becomes a real header line.
        _ = try await sendService.sendNew(
            to: ["to@example.com"],
            body: "Hello world",
            subject: "Subject",
            messageId: injectedMessageID
        )

        let mime = try decodedMIMEFromFirstSendCall()
        XCTAssertEqual(headerLines(in: mime, named: "Bcc"), [])
        XCTAssertEqual(headerLines(in: mime, named: "Message-ID"), [collapsedInjectedMessageIDHeader])
    }

    func testSendNew_deterministicReconciliationMessageID_survivesSanitizationByteIdentically() async throws {
        // HONEST SCOPE: this test PASSES with the sanitizeHeaderValue call deleted — it
        // pins the no-op direction only, failing if the sanitizer is ever STRENGTHENED
        // to rewrite a deterministic ID. Sync matches an outbound echo by re-deriving
        // this exact string, so even a one-byte rewrite silently breaks send
        // convergence. Deletion of the call is caught by the injection tests instead.
        let messageID = MimeBuilder.messageId(forOptimisticMessageID: "optimistic-id")

        _ = try await sendService.sendNew(
            to: ["to@example.com"],
            body: "Hello world",
            subject: "Subject",
            messageId: messageID
        )

        let mime = try decodedMIMEFromFirstSendCall()
        let emitted = try emittedMessageIDValue(in: mime)
        XCTAssertEqual(emitted, messageID)
        XCTAssertEqual(MimeBuilder.optimisticMessageID(from: emitted), "optimistic-id")
    }

    func testBuildSimpleMessage_messageID_blocksInjectionAndPreservesDeterministicID() throws {
        // Revert-check: MimeBuilder.sanitizeHeaderValue applied to the Message-ID value in
        // MimeBuilder.buildSimpleMessage.
        let injected = try decodedMIME(
            MimeBuilder.buildSimpleMessage(
                to: ["to@example.com"],
                from: "sender@example.com",
                fromName: nil,
                body: "Hello world",
                subject: "Subject",
                inReplyTo: nil,
                references: [],
                messageId: injectedMessageID
            )
        )
        XCTAssertEqual(headerLines(in: injected, named: "Bcc"), [])
        XCTAssertEqual(headerLines(in: injected, named: "Message-ID"), [collapsedInjectedMessageIDHeader])

        let deterministicID = MimeBuilder.messageId(forOptimisticMessageID: "optimistic-id")
        let preserved = try decodedMIME(
            MimeBuilder.buildSimpleMessage(
                to: ["to@example.com"],
                from: "sender@example.com",
                fromName: nil,
                body: "Hello world",
                subject: "Subject",
                inReplyTo: nil,
                references: [],
                messageId: deterministicID
            )
        )
        XCTAssertEqual(try emittedMessageIDValue(in: preserved), deterministicID)
    }

    func testBuildAlternativeMessage_messageID_blocksInjectionAndPreservesDeterministicID() throws {
        // Revert-check: MimeBuilder.sanitizeHeaderValue applied to the Message-ID value in
        // MimeBuilder.buildAlternativeMessage.
        let injected = try decodedMIME(
            MimeBuilder.buildAlternativeMessage(
                to: ["to@example.com"],
                from: "sender@example.com",
                fromName: nil,
                body: "Hello world",
                htmlBody: "<p>Hello world</p>",
                subject: "Subject",
                inReplyTo: nil,
                references: [],
                attachments: [],
                inlineAttachments: [],
                messageId: injectedMessageID
            )
        )
        XCTAssertEqual(headerLines(in: injected, named: "Bcc"), [])
        XCTAssertEqual(headerLines(in: injected, named: "Message-ID"), [collapsedInjectedMessageIDHeader])

        let deterministicID = MimeBuilder.messageId(forOptimisticMessageID: "optimistic-id")
        let preserved = try decodedMIME(
            MimeBuilder.buildAlternativeMessage(
                to: ["to@example.com"],
                from: "sender@example.com",
                fromName: nil,
                body: "Hello world",
                htmlBody: "<p>Hello world</p>",
                subject: "Subject",
                inReplyTo: nil,
                references: [],
                attachments: [],
                inlineAttachments: [],
                messageId: deterministicID
            )
        )
        XCTAssertEqual(try emittedMessageIDValue(in: preserved), deterministicID)
    }

    func testBuildMultipartMessage_messageID_blocksInjectionAndPreservesDeterministicID() throws {
        // Revert-check: MimeBuilder.sanitizeHeaderValue applied to the Message-ID value in
        // MimeBuilder.buildMultipartMessage.
        let attachment = AttachmentData(
            data: Data("attachment".utf8),
            filename: "note.txt",
            mimeType: "text/plain"
        )
        let injected = try decodedMIME(
            MimeBuilder.buildMultipartMessage(
                to: ["to@example.com"],
                from: "sender@example.com",
                fromName: nil,
                body: "Hello world",
                subject: "Subject",
                inReplyTo: nil,
                references: [],
                attachments: [attachment],
                messageId: injectedMessageID
            )
        )
        XCTAssertEqual(headerLines(in: injected, named: "Bcc"), [])
        XCTAssertEqual(headerLines(in: injected, named: "Message-ID"), [collapsedInjectedMessageIDHeader])

        let deterministicID = MimeBuilder.messageId(forOptimisticMessageID: "optimistic-id")
        let preserved = try decodedMIME(
            MimeBuilder.buildMultipartMessage(
                to: ["to@example.com"],
                from: "sender@example.com",
                fromName: nil,
                body: "Hello world",
                subject: "Subject",
                inReplyTo: nil,
                references: [],
                attachments: [attachment],
                messageId: deterministicID
            )
        )
        XCTAssertEqual(try emittedMessageIDValue(in: preserved), deterministicID)
    }

    func testSendReply_passesThreadIdToInjectedGmailAPIClient() async throws {
        _ = try await sendService.sendReply(
            to: ["to@example.com"],
            body: "Reply body",
            subject: "Re: Subject",
            threadId: "reply-thread-id",
            inReplyTo: "<id-1>",
            references: ["<id-1>"]
        )

        XCTAssertEqual(apiClient.sendMessageCallCount, 1)
        XCTAssertEqual(apiClient.sendMessageCalls.first?.threadId, "reply-thread-id")
    }

    func testSendReply_invokesTransmissionBarrierBeforeAPIRequest() async throws {
        let probe = TransmissionBarrierProbe()

        _ = try await sendService.sendReply(
            to: ["to@example.com"],
            body: "Reply body",
            subject: "Re: Subject",
            threadId: "reply-thread-id",
            inReplyTo: "<id-1>",
            references: ["<id-1>"],
            beforeTransmission: {
                await probe.record()
            }
        )

        let barrierCallCount = await probe.callCount()
        XCTAssertEqual(barrierCallCount, 1)
        XCTAssertEqual(apiClient.sendMessageCallCount, 1)
    }

    func testSendNew_attachmentPreflightFailureDoesNotCrossTransmissionBarrier() async {
        let probe = TransmissionBarrierProbe()

        do {
            _ = try await sendService.sendNew(
                to: ["to@example.com"],
                body: "Hello world",
                attachmentInfos: [
                    .init(
                        localURL: nil,
                        filename: "missing.pdf",
                        mimeType: "application/pdf"
                    )
                ],
                beforeTransmission: {
                    await probe.record()
                }
            )
            XCTFail("Expected attachment preflight failure")
        } catch {
            // Expected definite local failure.
        }

        let barrierCallCount = await probe.callCount()
        XCTAssertEqual(barrierCallCount, 0)
        XCTAssertEqual(apiClient.sendMessageCallCount, 0)
    }

    func testSendNew_preflightCancellationDoesNotCrossTransmissionBarrier() async {
        let probe = TransmissionBarrierProbe()
        let task = Task {
            try await sendService.sendNew(
                to: ["to@example.com"],
                body: "Hello world",
                beforeTransmission: {
                    await probe.record()
                }
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected before request admission.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let barrierCallCount = await probe.callCount()
        XCTAssertEqual(barrierCallCount, 0)
        XCTAssertEqual(apiClient.sendMessageCallCount, 0)
    }

    func testSendNew_transmissionBarrierFailurePreventsAPIRequest() async {
        let probe = TransmissionBarrierProbe()

        do {
            _ = try await sendService.sendNew(
                to: ["to@example.com"],
                body: "Hello world",
                beforeTransmission: {
                    await probe.record()
                    throw TransmissionBarrierTestError.persistenceFailed
                }
            )
            XCTFail("Expected barrier persistence failure")
        } catch TransmissionBarrierTestError.persistenceFailed {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let barrierCallCount = await probe.callCount()
        XCTAssertEqual(barrierCallCount, 1)
        XCTAssertEqual(apiClient.sendMessageCallCount, 0)
    }

    func testSendNew_mapsAuthenticationErrorsFromAPIClient() async {
        apiClient.sendMessageError = APIError.authenticationError

        do {
            _ = try await sendService.sendNew(
                to: ["to@example.com"],
                body: "Hello world",
                subject: "Subject"
            )
            XCTFail("Expected authentication failure")
        } catch let error as GmailSendService.SendError {
            if case .authenticationFailed = error {
                return
            }
            XCTFail("Expected authenticationFailed but got \(error)")
        } catch {
            XCTFail("Expected GmailSendService.SendError.authenticationFailed but got \(error)")
        }
    }

    func testAttachmentSnapshot_doesNotMutateAttachmentState() {
        let attachment = coreDataStack.viewContext.insertTestObject(Attachment.self)
        attachment.id = "inline-1"
        attachment.filename = "inline.png"
        attachment.mimeType = "image/png"
        attachment.stateRaw = Attachment.State.downloaded.rawValue
        attachment.contentId = "cid-inline"

        let info = sendService.attachmentSnapshot(attachment)

        XCTAssertEqual(attachment.state, .downloaded)
        XCTAssertEqual(info.filename, "inline.png")
        XCTAssertEqual(info.mimeType, "image/png")
        XCTAssertEqual(info.contentId, "cid-inline")
    }

    // MARK: - MIME Helpers

    private func decodedMIMEFromFirstSendCall() throws -> String {
        let rawMessage = try XCTUnwrap(apiClient.sendMessageCalls.first?.rawMessage)
        let mimeData = try XCTUnwrap(Data(base64UrlEncoded: rawMessage))
        return try decodedMIME(mimeData)
    }

    private func decodedMIME(_ mimeData: Data) throws -> String {
        try XCTUnwrap(String(data: mimeData, encoding: .utf8))
    }

    /// Header lines are matched on the raw CRLF-delimited line boundaries, so an injected
    /// value that survives only *inside* another header's value is not counted as a header.
    /// NOTE: splits on CRLF only, so against a sanitizer weakened to bare-LF the Bcc
    /// emptiness assertion would still pass — the Message-ID EQUALITY assertion is the
    /// load-bearing one in every injection test (an uncollapsed value cannot equal the
    /// collapsed expectation).
    private func headerLines(in mime: String, named name: String) -> [String] {
        mime
            .components(separatedBy: "\r\n")
            .filter { $0.hasPrefix("\(name):") }
    }

    private func emittedMessageIDValue(in mime: String) throws -> String {
        let lines = headerLines(in: mime, named: "Message-ID")
        XCTAssertEqual(lines.count, 1)
        let line = try XCTUnwrap(lines.first)
        return String(line.dropFirst("Message-ID: ".count))
    }
}

private let injectedMessageID = "<a@b>\r\nBcc: attacker@example.com"
private let collapsedInjectedMessageIDHeader = "Message-ID: <a@b> Bcc: attacker@example.com"

private enum TransmissionBarrierTestError: Error {
    case persistenceFailed
}

private actor TransmissionBarrierProbe {
    private var calls = 0

    func record() {
        calls += 1
    }

    func callCount() -> Int {
        calls
    }
}
