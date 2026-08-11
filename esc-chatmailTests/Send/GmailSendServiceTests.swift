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
}

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
