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

    func testSend_waitsForAttachmentImportFinalizationBeforeInvokingCoordinator() async {
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
        viewModel.addRecipient(email: "friend@example.com")
        viewModel.body = "Hello with attachment"

        let attachment = deps.viewContext.insertTestObject(Attachment.self)
        attachment.id = "local_\(UUID().uuidString)"
        attachment.filename = "photo.jpg"
        attachment.mimeType = "image/jpeg"
        attachment.stateRaw = Attachment.State.queued.rawValue
        viewModel.addAttachment(attachment)
        defer { viewModel.attachmentManager.clear() }

        let importID = UUID()
        viewModel.setAttachmentImportInProgress(true, id: importID)

        XCTAssertTrue(viewModel.isImportingAttachments)
        XCTAssertFalse(viewModel.canSend)
        let didSendDuringImport = await viewModel.send()
        XCTAssertFalse(didSendDuringImport)
        XCTAssertNil(coordinator.lastRequest)

        viewModel.setAttachmentImportInProgress(false, id: importID)

        XCTAssertFalse(viewModel.isImportingAttachments)
        XCTAssertFalse(viewModel.canSend, "An unfinished placeholder must remain unsendable")
        let didSendUnfinishedAttachment = await viewModel.send()
        XCTAssertFalse(didSendUnfinishedAttachment)
        XCTAssertNil(coordinator.lastRequest)

        attachment.localURL = AttachmentPaths.originalPath(
            idOrUUID: attachment.id ?? UUID().uuidString,
            ext: "jpg"
        )

        XCTAssertTrue(viewModel.canSend)
        let didSendFinalizedAttachment = await viewModel.send()
        XCTAssertTrue(didSendFinalizedAttachment)
        XCTAssertNotNil(coordinator.lastRequest)
    }

    func testSend_freezesStructuralDraftMutationUntilTransmissionAdmission() async throws {
        let authSession = makeTestAuthSession(userEmail: "me@example.com")
        let coordinator = MockOutboundMessageCoordinator()
        coordinator.suspendsSend = true
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
        viewModel.addRecipient(email: "friend@example.com")
        viewModel.body = "Captured body"
        let capturedAttachment = deps.viewContext.insertTestObject(Attachment.self)
        capturedAttachment.id = "local_captured-attachment"
        capturedAttachment.localURL = AttachmentPaths.originalPath(
            idOrUUID: "local_captured-attachment",
            ext: "jpg"
        )
        viewModel.addAttachment(capturedAttachment)
        defer {
            coordinator.resumeSend()
            viewModel.attachmentManager.clear()
        }

        let sendTask = Task { await viewModel.send() }
        await waitUntil { coordinator.lastRequest != nil }

        XCTAssertTrue(viewModel.isSending)
        viewModel.recipientInput = "new@example.com"
        viewModel.addRecipient(email: "new@example.com")
        viewModel.removeRecipient(try XCTUnwrap(viewModel.recipients.first))
        viewModel.removeAttachment(capturedAttachment)
        let laterAttachment = deps.viewContext.insertTestObject(Attachment.self)
        laterAttachment.id = "later-attachment"
        viewModel.addAttachment(laterAttachment)

        XCTAssertEqual(viewModel.recipients.map(\.email), ["friend@example.com"])
        XCTAssertEqual(viewModel.recipientInput, "")
        XCTAssertEqual(viewModel.attachments.map(\.id), ["local_captured-attachment"])

        coordinator.resumeSend()
        let didSend = await sendTask.value
        XCTAssertTrue(didSend)
        XCTAssertFalse(viewModel.isSending)
    }

    func testSendFailurePublishesSingleAlertValue() async {
        let authSession = makeTestAuthSession(userEmail: "me@example.com")
        let coordinator = MockOutboundMessageCoordinator()
        coordinator.errorToThrow = TestSendError.failed
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
        viewModel.addRecipient(email: "friend@example.com")
        viewModel.body = "Hello"

        let didSend = await viewModel.send()

        XCTAssertFalse(didSend)
        XCTAssertFalse(viewModel.isSending)
        XCTAssertEqual(viewModel.errorAlert?.message, TestSendError.failed.localizedDescription)
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

@MainActor
private final class MockOutboundMessageCoordinator: OutboundMessageCoordinating {
    private let coreDataStack: TestCoreDataStack
    private(set) var lastRequest: OutboundMessageRequest?
    var suspendsSend = false
    var errorToThrow: Error?
    private var sendContinuation: CheckedContinuation<Void, Never>?

    init() {
        coreDataStack = TestCoreDataStack()
    }

    func send(
        preparing requestBuilder: @escaping @MainActor () async throws -> OutboundMessageRequest,
        reconciliationHooks: OutboundMessageReconciliationHooks
    ) async throws -> OutboundMessageResult? {
        let request = try await requestBuilder()
        lastRequest = request
        if let errorToThrow {
            throw errorToThrow
        }
        if suspendsSend {
            await withCheckedContinuation { continuation in
                sendContinuation = continuation
            }
        }
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

    func resumeSend() {
        sendContinuation?.resume()
        sendContinuation = nil
    }
}

private enum TestSendError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Test send failed"
    }
}
