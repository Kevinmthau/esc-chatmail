import XCTest
import Combine
@testable import esc_chatmail

@MainActor
final class ComposeViewModelTests: XCTestCase {
    private func makeTestAuthSession(userEmail: String? = nil) -> AuthSession {
        let authSession = AuthSession(
            tokenManagerProvider: { MockTokenManager() },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(suiteName: "ComposeViewModelTests.\(UUID().uuidString)")!,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
        authSession.userEmail = userEmail
        return authSession
    }

    private func makeDependencies(authSession: AuthSession) -> Dependencies {
        let tokenManager = MockTokenManager()
        return Dependencies(
            authSession: authSession,
            tokenManager: tokenManager,
            gmailAPIClient: GmailAPIClient(tokenManager: tokenManager)
        )
    }

    func testAddAttachment_forwardsAttachmentManagerChanges() {
        let deps = makeDependencies(authSession: makeTestAuthSession())
        let viewModel = ComposeViewModel(mode: .newMessage, deps: deps)
        let attachment = Attachment(context: deps.viewContext)
        attachment.id = "local_\(UUID().uuidString)"
        attachment.filename = "photo.jpg"
        attachment.mimeType = "image/jpeg"
        attachment.stateRaw = Attachment.State.queued.rawValue

        let changeExpectation = expectation(description: "ComposeViewModel emits objectWillChange")
        let cancellable = viewModel.objectWillChange.sink { _ in
            changeExpectation.fulfill()
        }
        defer {
            cancellable.cancel()
            viewModel.attachmentManager.clear()
        }

        viewModel.addAttachment(attachment)

        wait(for: [changeExpectation], timeout: 1.0)
        XCTAssertEqual(viewModel.attachments.count, 1)
        XCTAssertEqual(viewModel.attachments.first?.id, attachment.id)
    }

    func testSetupForMode_replyIsIdempotent() {
        let authSession = makeTestAuthSession(userEmail: "me@example.com")
        let deps = makeDependencies(authSession: authSession)

        let replyModeContext = deps.makeComposeReplyModeContextBuilder().build(
            input: .init(
                initialRecipients: [
                    Recipient(email: "friend@example.com", displayName: "Friend")
                ],
                conversation: .init(
                    participantEmails: ["me@example.com", "friend@example.com"],
                    latestThreadId: "thread-123"
                ),
                replyingTo: nil,
                optimisticConversation: .existingConversation("x-coredata://conversation/123")
            )
        )
        let viewModel = ComposeViewModel(mode: .reply(replyModeContext), deps: deps)

        viewModel.setupForMode()
        viewModel.setupForMode()

        XCTAssertEqual(viewModel.recipients.map(\.email), ["friend@example.com"])
    }

    func testSend_newMessageBuildsParticipantHashOptimisticConversationContext() async {
        let authSession = makeTestAuthSession(userEmail: "me@example.com")
        let coordinator = MockOutboundMessageCoordinator()
        let tokenManager = MockTokenManager()
        let deps = Dependencies(
            authSession: authSession,
            tokenManager: tokenManager,
            gmailAPIClient: GmailAPIClient(tokenManager: tokenManager),
            outboundMessageCoordinator: coordinator
        )
        let viewModel = ComposeViewModel(mode: .newMessage, deps: deps)
        viewModel.addRecipient(email: "Friend@example.com")
        viewModel.body = "Hello"

        let didSend = await viewModel.send()

        XCTAssertTrue(didSend)
        guard case .compose(let request)? = coordinator.lastRequest else {
            return XCTFail("Expected compose request")
        }
        XCTAssertEqual(request.recipientEmails, ["Friend@example.com"])
        XCTAssertEqual(
            request.optimisticConversation?.participantHash,
            calculateParticipantHash(from: [EmailNormalizer.normalize("Friend@example.com")])
        )
    }
}

@MainActor
private final class MockOutboundMessageCoordinator: OutboundMessageCoordinating {
    private(set) var lastRequest: OutboundMessageRequest?

    func send(
        _ request: OutboundMessageRequest,
        reconciliationHooks: OutboundMessageReconciliationHooks
    ) async throws -> OutboundMessageResult? {
        lastRequest = request
        return .init(
            optimisticMessageID: "optimistic-1",
            conversationObjectURI: "x-coredata://conversation/123"
        )
    }
}
