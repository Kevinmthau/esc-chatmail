import XCTest
import CoreData
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
        let viewModel = ComposeViewModel(
            mode: .newMessage,
            dependencies: deps.makeComposeDependencies()
        )
        let attachment = deps.viewContext.insertTestObject(Attachment.self)
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

    func testSetupForMode_replyIsIdempotent() throws {
        let authSession = makeTestAuthSession(userEmail: "me@example.com")
        let deps = makeDependencies(authSession: authSession)
        let context = deps.viewContext
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: context)
        try context.obtainPermanentIDs(for: [conversation])

        let replyModeContext = deps.makeComposeReplyModeContextBuilder().build(
            input: .init(
                initialRecipients: [
                    Recipient(email: "friend@example.com", displayName: "Friend")
                ],
                conversationObjectID: conversation.objectID,
                replyingToMessageObjectID: nil,
                optimisticConversation: .existingConversation(
                    ConversationReference(objectID: conversation.objectID)
                )
            )
        )
        let viewModel = ComposeViewModel(
            mode: .reply(replyModeContext),
            dependencies: deps.makeComposeDependencies()
        )

        viewModel.setupForMode()
        viewModel.setupForMode()

        XCTAssertEqual(viewModel.recipients.map(\.email), ["friend@example.com"])
    }

    func testSetupForMode_forwardCopiesForwardAttachmentSnapshots() {
        let deps = makeDependencies(authSession: makeTestAuthSession(userEmail: "me@example.com"))
        AttachmentPaths.setupDirectories()

        let regularPath = AttachmentPaths.originalPath(idOrUUID: "forward-regular", ext: "pdf")
        XCTAssertTrue(AttachmentPaths.saveData(Data("regular".utf8), to: regularPath))
        defer { AttachmentPaths.deleteFile(at: regularPath) }

        let forwardModeContext = ComposeForwardModeContext(
            id: "forward-source-message",
            initialSubject: "Fwd: Original Subject",
            forwardedPlainTextBody: "Forwarded body",
            forwardedHTMLBody: "<html><body><p>Forwarded HTML body</p></body></html>",
            forwardedInlineAttachmentInfos: [],
            forwardedRegularAttachments: [
                .init(
                    filename: "report.pdf",
                    mimeType: "application/pdf",
                    byteSize: 91_248,
                    localURL: regularPath,
                    previewURL: nil,
                    width: 0,
                    height: 0,
                    pageCount: 0
                ),
                .init(
                    filename: "missing.pdf",
                    mimeType: "application/pdf",
                    byteSize: 10,
                    localURL: "Attachments/missing.pdf",
                    previewURL: nil,
                    width: 0,
                    height: 0,
                    pageCount: 0
                )
            ]
        )
        let viewModel = ComposeViewModel(
            mode: .forward(forwardModeContext),
            dependencies: deps.makeComposeDependencies()
        )
        defer { viewModel.attachmentManager.clear() }

        viewModel.setupForMode()
        viewModel.setupForMode()

        XCTAssertEqual(viewModel.subject, "Fwd: Original Subject")
        XCTAssertEqual(viewModel.attachments.count, 1)
        XCTAssertEqual(viewModel.attachments.first?.filename, "report.pdf")
        XCTAssertEqual(viewModel.skippedForwardAttachmentCount, 1)
    }

    func testUpdateForwardedPreviewHTML_cachesWrappedPreviewAndRefreshesForColorScheme() throws {
        let deps = makeDependencies(authSession: makeTestAuthSession(userEmail: "me@example.com"))
        let forwardModeContext = ComposeForwardModeContext(
            id: "forward-source-message",
            initialSubject: "Fwd: Original Subject",
            forwardedPlainTextBody: "Forwarded body",
            forwardedHTMLBody: """
            <!DOCTYPE html>
            <html>
            <body><p>Forwarded HTML body</p></body>
            </html>
            """,
            forwardedInlineAttachmentInfos: [],
            forwardedRegularAttachments: []
        )
        let viewModel = ComposeViewModel(
            mode: .forward(forwardModeContext),
            dependencies: deps.makeComposeDependencies()
        )

        viewModel.setupForMode()
        XCTAssertNil(viewModel.forwardedPreviewHTML)

        viewModel.updateForwardedPreviewHTML(isDarkMode: false)
        let lightPreview = try XCTUnwrap(viewModel.forwardedPreviewHTML)

        XCTAssertTrue(lightPreview.contains("Forwarded HTML body"))
        XCTAssertTrue(lightPreview.contains("background-color: #f2f2f7;"))

        viewModel.body = "Typing should not change the cached forwarded preview"
        viewModel.updateForwardedPreviewHTML(isDarkMode: false)

        XCTAssertEqual(viewModel.forwardedPreviewHTML, lightPreview)

        viewModel.updateForwardedPreviewHTML(isDarkMode: true)
        let darkPreview = try XCTUnwrap(viewModel.forwardedPreviewHTML)

        XCTAssertTrue(darkPreview.contains("Forwarded HTML body"))
        XCTAssertTrue(darkPreview.contains("background-color: #1c1c1e;"))
        XCTAssertNotEqual(darkPreview, lightPreview)
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
        let viewModel = ComposeViewModel(
            mode: .newMessage,
            dependencies: deps.makeComposeDependencies()
        )
        viewModel.addRecipient(email: "Friend@example.com")
        viewModel.body = "Hello"

        let didSend = await viewModel.send()

        XCTAssertTrue(didSend)
        guard case .compose(let request)? = coordinator.lastRequest else {
            return XCTFail("Expected compose request")
        }
        XCTAssertEqual(request.recipientEmails, ["friend@example.com"])
        XCTAssertEqual(
            request.optimisticConversation?.participantHashValue,
            calculateParticipantHash(from: [EmailNormalizer.normalize("Friend@example.com")])
        )
    }
}

@MainActor
private final class MockOutboundMessageCoordinator: OutboundMessageCoordinating {
    private let coreDataStack: TestCoreDataStack
    private(set) var lastRequest: OutboundMessageRequest?

    init() {
        coreDataStack = TestCoreDataStack()
    }

    func send(
        _ request: OutboundMessageRequest,
        reconciliationHooks: OutboundMessageReconciliationHooks
    ) async throws -> OutboundMessageResult? {
        lastRequest = request
        let message = coreDataStack.viewContext.insertTestObject(Message.self)
        message.id = "optimistic-1"
        try coreDataStack.viewContext.obtainPermanentIDs(for: [message])
        return .init(
            optimisticMessageID: message.id,
            optimisticMessageObjectID: message.objectID,
            conversationReference: ConversationReference(
                persistentStoreURI: URL(string: "x-coredata://conversation/123")!
            )
        )
    }
}
