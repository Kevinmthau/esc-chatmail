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

    func testForwardSetupCopiesInlineResourcesAndDiscardDeletesOnlyDraftCopies() throws {
        let deps = makeDependencies(authSession: makeTestAuthSession(userEmail: "me@example.com"))
        AttachmentPaths.setupDirectories()
        let sourcePath = AttachmentPaths.originalPath(idOrUUID: UUID().uuidString, ext: "png")
        let sourceData = Data([0x89, 0x50, 0x4E, 0x47])
        XCTAssertTrue(AttachmentPaths.saveData(sourceData, to: sourcePath))
        defer { AttachmentPaths.deleteFile(at: sourcePath) }
        let viewModel = ComposeViewModel(
            mode: .forward(.init(
                id: UUID().uuidString,
                initialSubject: "Fwd: Image",
                forwardedPlainTextBody: "Image body",
                forwardedHTMLBody: "<img src=\"cid:logo@example.com\">",
                forwardedInlineAttachmentInfos: [.init(localURL: sourcePath, filename: "logo.png", mimeType: "image/png", contentId: "logo@example.com")],
                forwardedRegularAttachments: [],
                initialRecipientEmails: ["friend@example.com"],
                initialBody: "My note"
            )),
            dependencies: deps.makeComposeDependencies()
        )
        defer { viewModel.discard() }
        XCTAssertFalse(viewModel.canSend)

        viewModel.setupForMode()

        XCTAssertTrue(viewModel.canSend)
        XCTAssertEqual(viewModel.body, "My note")
        let resource = try XCTUnwrap(viewModel.forwardedPreviewInlineResources.first)
        XCTAssertNotEqual(resource.localURL, sourcePath)
        XCTAssertEqual(AttachmentPaths.loadData(from: resource.localURL), sourceData)

        viewModel.presentationDidDisappear(isPresented: true)
        XCTAssertTrue(viewModel.canSend, "A nested picker covering the composer must preserve the draft")
        XCTAssertEqual(AttachmentPaths.loadData(from: resource.localURL), sourceData)

        viewModel.presentationDidDisappear(isPresented: false)

        XCTAssertNil(AttachmentPaths.loadData(from: resource.localURL))
        XCTAssertEqual(AttachmentPaths.loadData(from: sourcePath), sourceData)
        XCTAssertTrue(viewModel.attachmentManager.inlineAttachments.isEmpty)
        XCTAssertFalse(viewModel.canSend, "A discarded composer cannot submit a previously queued send")
    }

    func testForwardSetupMissingInlineAttachmentBlocksSending() {
        let deps = makeDependencies(authSession: makeTestAuthSession(userEmail: "me@example.com"))
        let viewModel = ComposeViewModel(
            mode: .forward(.init(
                id: UUID().uuidString,
                initialSubject: "Fwd: Image",
                forwardedPlainTextBody: "Image body",
                forwardedHTMLBody: "<img src=\"cid:logo@example.com\">",
                forwardedInlineAttachmentInfos: [.init(localURL: "Attachments/\(UUID().uuidString).png", filename: "logo.png", mimeType: "image/png", contentId: "logo@example.com")],
                forwardedRegularAttachments: [],
                initialRecipientEmails: ["friend@example.com"]
            )),
            dependencies: deps.makeComposeDependencies()
        )

        viewModel.setupForMode()

        XCTAssertFalse(viewModel.canSend)
        XCTAssertNotNil(viewModel.errorAlert)
        XCTAssertTrue(viewModel.attachmentManager.inlineAttachments.isEmpty)
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

    func testSend_forwardIncludesInlineFilesInCombinedAttachmentBudget() async throws {
        let coordinator = MockOutboundMessageCoordinator()
        let tokenManager = MockTokenManager()
        let deps = Dependencies(
            authSession: makeTestAuthSession(userEmail: "me@example.com"),
            tokenManager: tokenManager,
            gmailAPIClient: GmailAPIClient(tokenManager: tokenManager),
            outboundMessageCoordinator: coordinator
        )
        AttachmentPaths.setupDirectories()
        let inlinePath = AttachmentPaths.originalPath(idOrUUID: UUID().uuidString, ext: "png")
        let regularPath = AttachmentPaths.originalPath(idOrUUID: UUID().uuidString, ext: "pdf")
        defer {
            AttachmentPaths.deleteFile(at: inlinePath)
            AttachmentPaths.deleteFile(at: regularPath)
        }
        for path in [inlinePath, regularPath] {
            XCTAssertTrue(AttachmentPaths.saveData(Data(), to: path))
            let file = try FileHandle(forWritingTo: XCTUnwrap(AttachmentPaths.fullURL(for: path)))
            try file.truncate(atOffset: 13 * 1024 * 1024)
            try file.close()
        }
        let viewModel = ComposeViewModel(
            mode: .forward(.init(
                id: "forward-source-message",
                initialSubject: "Fwd: Original Subject",
                forwardedPlainTextBody: "Forwarded body",
                forwardedHTMLBody: "<img src=\"cid:inline@example.com\">",
                forwardedInlineAttachmentInfos: [
                    .init(localURL: inlinePath, filename: "inline.png", mimeType: "image/png", contentId: "inline@example.com")
                ],
                forwardedRegularAttachments: [
                    .init(
                        filename: "report.pdf",
                        mimeType: "application/pdf",
                        byteSize: 0,
                        localURL: regularPath,
                        previewURL: nil,
                        width: 0,
                        height: 0,
                        pageCount: 0
                    )
                ]
            )),
            dependencies: deps.makeComposeDependencies()
        )
        defer { viewModel.attachmentManager.clear() }
        viewModel.setupForMode()
        viewModel.addRecipient(email: "friend@example.com")
        let draftPaths = (viewModel.attachments + viewModel.attachmentManager.inlineAttachments).compactMap(\.localURL)
        defer { draftPaths.forEach { AttachmentPaths.deleteFile(at: $0) } }

        XCTAssertTrue(viewModel.canSend)
        let didSendOverBudget = await viewModel.send()

        XCTAssertFalse(didSendOverBudget)
        XCTAssertNil(coordinator.lastRequest, "Combined attachment size must be checked before submitting the forward")
        XCTAssertFalse(viewModel.isSending)
        XCTAssertEqual(
            viewModel.errorAlert?.message,
            DraftAttachmentImport.ImportError.sizeLimit(filename: "report.pdf").localizedDescription
        )

        // Reducing the regular file to 12 MiB puts the combined total at the 25 MiB limit.
        let copiedAttachment = try XCTUnwrap(viewModel.attachments.first)
        let copiedURL = try XCTUnwrap(AttachmentPaths.fullURL(for: copiedAttachment.localURL))
        let file = try FileHandle(forWritingTo: copiedURL)
        try file.truncate(atOffset: 12 * 1024 * 1024)
        try file.close()

        let didSendWithinBudget = await viewModel.send()

        XCTAssertTrue(didSendWithinBudget)
        XCTAssertNil(viewModel.errorAlert)
        guard case .forward(let request)? = coordinator.lastRequest else {
            return XCTFail("Expected forward request")
        }
        XCTAssertEqual(request.attachments.map(\.info.filename), ["report.pdf"])
        XCTAssertEqual(request.forwardedInlineAttachmentInfos.map(\.contentId), ["inline@example.com"])
        XCTAssertEqual(request.inlineAttachments.count, 1)
    }

    func testForwardRemovingRegularAttachmentAllowsRetryAfterCombinedSizeError() async throws {
        let coordinator = MockOutboundMessageCoordinator()
        let tokenManager = MockTokenManager()
        let deps = Dependencies(
            authSession: makeTestAuthSession(userEmail: "me@example.com"),
            tokenManager: tokenManager,
            gmailAPIClient: GmailAPIClient(tokenManager: tokenManager),
            outboundMessageCoordinator: coordinator
        )
        AttachmentPaths.setupDirectories()
        let inlinePath = AttachmentPaths.originalPath(idOrUUID: UUID().uuidString, ext: "png")
        let regularPath = AttachmentPaths.originalPath(idOrUUID: UUID().uuidString, ext: "pdf")
        defer {
            AttachmentPaths.deleteFile(at: inlinePath)
            AttachmentPaths.deleteFile(at: regularPath)
        }
        for path in [inlinePath, regularPath] {
            XCTAssertTrue(AttachmentPaths.saveData(Data(), to: path))
            let file = try FileHandle(forWritingTo: XCTUnwrap(AttachmentPaths.fullURL(for: path)))
            try file.truncate(atOffset: 13 * 1024 * 1024)
            try file.close()
        }
        let viewModel = ComposeViewModel(
            mode: .forward(.init(
                id: UUID().uuidString,
                initialSubject: "Fwd: Files",
                forwardedPlainTextBody: "Forwarded body",
                forwardedHTMLBody: "<img src=\"cid:logo@example.com\">",
                forwardedInlineAttachmentInfos: [.init(localURL: inlinePath, filename: "logo.png", mimeType: "image/png", contentId: "logo@example.com")],
                forwardedRegularAttachments: [.init(filename: "report.pdf", mimeType: "application/pdf", byteSize: 0, localURL: regularPath, previewURL: nil, width: 0, height: 0, pageCount: 0)],
                initialRecipientEmails: ["friend@example.com"]
            )),
            dependencies: deps.makeComposeDependencies()
        )
        viewModel.setupForMode()
        let inlineCopy = try XCTUnwrap(viewModel.forwardedPreviewInlineResources.first)
        defer {
            viewModel.discard()
            AttachmentPaths.deleteFile(at: inlineCopy.localURL)
        }

        let failedSend = await viewModel.send()
        XCTAssertFalse(failedSend)
        let attachment = try XCTUnwrap(viewModel.attachments.first)
        viewModel.removeAttachment(attachment)
        let successfulSend = await viewModel.send()

        XCTAssertTrue(successfulSend)
        guard case .forward(let request)? = coordinator.lastRequest else { return XCTFail("Expected forward request") }
        XCTAssertTrue(request.attachments.isEmpty)
        XCTAssertEqual(request.inlineAttachments.count, 1)
        XCTAssertEqual(request.forwardedInlineAttachmentInfos.first?.localURL, inlineCopy.localURL)
        viewModel.discard()
        XCTAssertNotNil(AttachmentPaths.loadData(from: inlineCopy.localURL), "Successful send handed the file to the optimistic message")
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

    func testSuccessfulForwardCannotSubmitASecondQueuedSend() async {
        let coordinator = MockOutboundMessageCoordinator()
        let tokenManager = MockTokenManager()
        let deps = Dependencies(
            authSession: makeTestAuthSession(userEmail: "me@example.com"),
            tokenManager: tokenManager,
            gmailAPIClient: GmailAPIClient(tokenManager: tokenManager),
            outboundMessageCoordinator: coordinator
        )
        let viewModel = ComposeViewModel(mode: .forward(.init(
            id: "queued-forward", initialSubject: "Fwd: Subject",
            forwardedPlainTextBody: "Original body", forwardedHTMLBody: nil,
            forwardedInlineAttachmentInfos: [], forwardedRegularAttachments: [],
            initialRecipientEmails: ["friend@example.com"]
        )), dependencies: deps.makeComposeDependencies())
        viewModel.setupForMode()

        let firstResult = await viewModel.send()
        let secondResult = await viewModel.send()

        XCTAssertTrue(firstResult)
        XCTAssertFalse(secondResult)
        XCTAssertEqual(coordinator.sendCount, 1)
    }

    /// Polls `condition` until it holds or `timeout` elapses. The condition is
    /// checked before the deadline on every pass, so a main-thread stall longer
    /// than the timeout cannot fail a condition that came true during the stall.
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            await Task.yield()
        }
    }
}

@MainActor
private final class MockOutboundMessageCoordinator: OutboundMessageCoordinating {
    private let coreDataStack: TestCoreDataStack
    private(set) var lastRequest: OutboundMessageRequest?
    private(set) var sendCount = 0
    var suspendsSend = false
    var errorToThrow: Error?
    private var sendContinuation: CheckedContinuation<Void, Never>?

    init() {
        coreDataStack = TestCoreDataStack()
    }

    func send(
        preparing requestBuilder: @escaping @MainActor () async throws -> OutboundMessageRequest,
        reconciliationHooks: OutboundMessageReconciliationHooks,
        onOptimisticMessagePersisted: (@MainActor (OutboundMessageResult) -> Void)?
    ) async throws -> OutboundMessageResult? {
        sendCount += 1
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
        let result = OutboundMessageResult(
            optimisticMessageID: message.id,
            optimisticMessageObjectID: message.objectID,
            conversationReference: ConversationReference(
                persistentStoreURI: URL(string: "x-coredata://conversation/123")!
            )
        )
        onOptimisticMessagePersisted?(result)
        return result
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
