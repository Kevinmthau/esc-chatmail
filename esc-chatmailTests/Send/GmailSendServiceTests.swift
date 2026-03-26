import XCTest
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
}
