import CoreData
import CoreGraphics
import XCTest
@testable import esc_chatmail

@MainActor
final class FullEmailReaderCoordinatorTests: XCTestCase {
    private var testStack: TestCoreDataStack!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        context = testStack.viewContext
    }

    override func tearDown() {
        context = nil
        testStack = nil
        super.tearDown()
    }

    func testOpenSession_readyPreparedArtifactCreatesPresentableSessionAndPrepaintsAfterMeasuredWidth() {
        let message = makeMessage(
            id: "prepared-message",
            subject: "Prepared subject",
            senderEmail: "sender@example.com",
            senderName: "Sender",
            snippet: "Prepared preview"
        )
        let artifact = makeArtifact(message: message)
        let opener = MockFullEmailReaderOpener(preparedArtifact: artifact)
        let coordinator = FullEmailReaderCoordinator(fullEmailOpener: opener)

        let session = coordinator.openSession(for: message)

        XCTAssertTrue(session.message === message)
        XCTAssertEqual(session.messageId, "prepared-message")
        XCTAssertEqual(session.messageObjectID, message.objectID)
        XCTAssertEqual(session.initialArtifact, artifact)
        XCTAssertEqual(session.readerState, .preparedArtifact(artifact, placeholder: session.immediatePlaceholder))
        XCTAssertEqual(session.immediatePlaceholder.subject, "Prepared subject")
        XCTAssertTrue(session.hasImmediateVisualSurface)
        XCTAssertEqual(opener.preparedPayloadRequests.count, 1)
        XCTAssertEqual(opener.preparedPayloadRequests.first?.request.messageId, "prepared-message")
        XCTAssertNil(opener.preparedPayloadRequests.first?.width)
        XCTAssertTrue(opener.prepaintRequests.isEmpty)

        session.prepareForMeasuredReaderWidth(390)

        XCTAssertEqual(opener.prepaintRequests.count, 1)
        XCTAssertEqual(opener.prepaintRequests.first?.request.messageId, "prepared-message")
        XCTAssertEqual(opener.prepaintRequests.first?.message.id, "prepared-message")
        XCTAssertEqual(opener.prepaintRequests.first?.artifact, artifact)
        XCTAssertEqual(opener.prepaintRequests.first?.width, 390)
        XCTAssertTrue(opener.prewarmedMessages.isEmpty)
    }

    func testOpenSession_preparedArtifactOnlyPrepaintsOncePerMeasuredWidth() {
        let message = makeMessage(
            id: "warming-prepared-message",
            subject: "Prepared subject",
            senderEmail: "sender@example.com",
            senderName: "Sender",
            snippet: "Prepared preview"
        )
        let artifact = makeArtifact(message: message)
        let opener = MockFullEmailReaderOpener(
            preparedArtifact: artifact,
            checkoutAvailability: .warming
        )
        let coordinator = FullEmailReaderCoordinator(fullEmailOpener: opener)

        let session = coordinator.openSession(for: message)

        XCTAssertTrue(session.message === message)
        XCTAssertEqual(session.initialArtifact, artifact)
        XCTAssertEqual(session.readerState, .preparedArtifact(artifact, placeholder: session.immediatePlaceholder))
        XCTAssertEqual(opener.preparedPayloadRequests.count, 1)
        XCTAssertTrue(opener.prepaintRequests.isEmpty)

        session.prepareForMeasuredReaderWidth(390.2)
        session.prepareForMeasuredReaderWidth(390.4)
        session.prepareForMeasuredReaderWidth(391)

        XCTAssertEqual(opener.prepaintRequests.count, 2)
        XCTAssertEqual(opener.prepaintRequests.first?.request.messageId, "warming-prepared-message")
        XCTAssertEqual(opener.prepaintRequests.first?.message.id, "warming-prepared-message")
        XCTAssertEqual(opener.prepaintRequests.first?.artifact, artifact)
        XCTAssertEqual(opener.prepaintRequests.first?.width, 390.2)
        XCTAssertTrue(opener.prewarmedMessages.isEmpty)
    }

    func testOpenSession_prepaintsUpdatedArtifactAtPreviouslyMeasuredWidth() async {
        let message = makeMessage(
            id: "updated-artifact-prepaint",
            subject: "Prepared subject",
            senderEmail: "sender@example.com",
            senderName: "Sender",
            snippet: "Prepared preview"
        )
        let initialArtifact = makeArtifact(
            message: message,
            html: "<html><body>Initial full email</body></html>",
            sourceSignature: "initial-source"
        )
        let updatedHTML = "<html><body>Updated full email</body></html>"
        let loader = SessionStubOriginalEmailSourceLoader(
            responses: [
                makeSource(
                    html: updatedHTML,
                    sourceSignature: "updated-source",
                    sourceKind: .html,
                    sourceLocation: .messageFile
                )
            ]
        )
        let opener = MockFullEmailReaderOpener(preparedArtifact: initialArtifact)
        let session = FullEmailOpenSession(
            message: message,
            request: OriginalEmailWarmRequest(
                messageId: message.id,
                bodyStorageURI: message.bodyStorageURI,
                bodyText: message.bodyTextValue,
                senderEmail: message.senderEmailValue,
                subject: message.subject
            ),
            initialArtifact: initialArtifact,
            immediatePlaceholder: FullEmailPlaceholder(message: message),
            fullEmailOpener: opener,
            originalEmailSourceLoader: loader,
            originalEmailLoadTimeout: 0.1,
            recoveringDelay: 0.005,
            onSourceLoaded: { _, _ in }
        )

        session.prepareForMeasuredReaderWidth(390)
        _ = await session.loadOriginalEmail(for: session.loadRequest)
        session.prepareForMeasuredReaderWidth(390)

        XCTAssertEqual(opener.prepaintRequests.count, 2)
        XCTAssertEqual(opener.prepaintRequests[0].artifact, initialArtifact)
        XCTAssertEqual(opener.prepaintRequests[1].artifact.sourceSignature, "updated-source")
        XCTAssertEqual(opener.prepaintRequests[1].artifact.body, .html(updatedHTML))
        XCTAssertEqual(opener.prepaintRequests[1].width, 390)
    }

    func testOpenSession_payloadMissCreatesPlaceholderAndStartsPrewarmFollowUp() {
        let message = makeMessage(
            id: "miss-message",
            subject: "Miss subject",
            senderEmail: "miss@example.com",
            senderName: "Miss Sender",
            snippet: "Miss snippet"
        )
        let opener = MockFullEmailReaderOpener(preparedArtifact: nil)
        let coordinator = FullEmailReaderCoordinator(fullEmailOpener: opener)

        let session = coordinator.openSession(for: message)

        XCTAssertTrue(session.message === message)
        XCTAssertNil(session.initialArtifact)
        XCTAssertEqual(session.readerState, .loading(session.immediatePlaceholder))
        XCTAssertEqual(session.immediatePlaceholder.subject, "Miss subject")
        XCTAssertEqual(session.immediatePlaceholder.senderDisplayText, "Miss Sender")
        XCTAssertEqual(session.immediatePlaceholder.previewText, "Miss snippet")
        XCTAssertTrue(session.hasImmediateVisualSurface)
        XCTAssertEqual(opener.preparedPayloadRequests.count, 1)
        XCTAssertTrue(opener.prepaintRequests.isEmpty)
        XCTAssertEqual(opener.prewarmedMessages.map(\.message.id), ["miss-message"])
        XCTAssertNil(opener.prewarmedMessages.first?.width)
    }

    func testOpenSession_withoutInitialPayloadIsImmediatelyPresentable() {
        let message = makeMessage(
            id: "placeholder-message",
            subject: "",
            senderEmail: "fallback@example.com",
            senderName: nil,
            snippet: " \n ",
            body: "Body preview from the message"
        )
        let opener = MockFullEmailReaderOpener(preparedArtifact: nil)
        let coordinator = FullEmailReaderCoordinator(fullEmailOpener: opener)

        let session = coordinator.openSession(for: message)

        XCTAssertNil(session.initialArtifact)
        XCTAssertEqual(session.immediatePlaceholder.subject, "No Subject")
        XCTAssertEqual(session.immediatePlaceholder.senderDisplayText, "fallback@example.com")
        XCTAssertEqual(session.immediatePlaceholder.previewText, "Body preview from the message")
        XCTAssertEqual(session.readerState, .loading(session.immediatePlaceholder))
        XCTAssertTrue(session.hasImmediateVisualSurface)
    }

    func testPlaceholder_bodyTextFallbackOnlyNormalizesBoundedPrefix() {
        let body = "Visible body text"
            + String(repeating: " ", count: FullEmailPlaceholder.bodyTextPreviewScanLimit)
            + "Late body text"
        let message = makeMessage(
            id: "bounded-body-preview",
            snippet: "",
            body: body
        )
        message.snippet = nil

        let placeholder = FullEmailPlaceholder(message: message)

        XCTAssertEqual(placeholder.previewText, "Visible body text")
    }

    func testPlaceholder_hugeBodyFallbackDoesNotExceedPreviewLimit() throws {
        let body = String(repeating: "a", count: FullEmailPlaceholder.bodyTextPreviewScanLimit * 2)
        let message = makeMessage(
            id: "huge-body-preview",
            snippet: "",
            body: body
        )
        message.snippet = nil

        let previewText = try XCTUnwrap(FullEmailPlaceholder(message: message).previewText)

        XCTAssertEqual(previewText.count, FullEmailPlaceholder.previewCharacterLimit)
        XCTAssertEqual(previewText, String(repeating: "a", count: FullEmailPlaceholder.previewCharacterLimit))
    }

    func testPlaceholder_previewFieldsTakePriorityOverBodyText() {
        let chatPreviewMessage = makeMessage(
            id: "priority-chat-preview",
            snippet: "Snippet preview",
            body: "Body preview"
        )
        chatPreviewMessage.chatPreviewText = "Chat preview"
        chatPreviewMessage.cleanedSnippet = "Cleaned preview"
        XCTAssertEqual(FullEmailPlaceholder(message: chatPreviewMessage).previewText, "Chat preview")

        let cleanedSnippetMessage = makeMessage(
            id: "priority-cleaned-snippet",
            snippet: "Snippet preview",
            body: "Body preview"
        )
        cleanedSnippetMessage.chatPreviewText = " \n\t "
        cleanedSnippetMessage.cleanedSnippet = "Cleaned preview"
        XCTAssertEqual(FullEmailPlaceholder(message: cleanedSnippetMessage).previewText, "Cleaned preview")

        let snippetMessage = makeMessage(
            id: "priority-snippet",
            snippet: "Snippet preview",
            body: "Body preview"
        )
        snippetMessage.chatPreviewText = nil
        snippetMessage.cleanedSnippet = " \n\t "
        XCTAssertEqual(FullEmailPlaceholder(message: snippetMessage).previewText, "Snippet preview")
    }

    func testOpenSession_preparedPayloadDoesNotNormalizeBodyBeyondFallbackScanLimit() {
        let body = "Prepared visible body"
            + String(repeating: " ", count: FullEmailPlaceholder.bodyTextPreviewScanLimit)
            + "Late prepared body"
        let message = makeMessage(
            id: "prepared-bounded-body-preview",
            snippet: "",
            body: body
        )
        message.snippet = nil
        let artifact = makeArtifact(message: message)
        let opener = MockFullEmailReaderOpener(preparedArtifact: artifact)
        let coordinator = FullEmailReaderCoordinator(fullEmailOpener: opener)

        let session = coordinator.openSession(for: message)

        XCTAssertEqual(session.readerState, .preparedArtifact(artifact, placeholder: session.immediatePlaceholder))
        XCTAssertEqual(session.immediatePlaceholder.previewText, "Prepared visible body")
        XCTAssertTrue(opener.prepaintRequests.isEmpty)
        XCTAssertTrue(opener.prewarmedMessages.isEmpty)
    }

    func testSessionWithInitialPayloadDoesNotEnterLoadingDuringFirstLoadTask() async throws {
        let message = makeMessage(id: "prepared-load-task")
        let artifact = makeArtifact(message: message)
        let loader = SessionStubOriginalEmailSourceLoader(
            responses: [nil],
            delayNanoseconds: 80_000_000
        )
        let session = makeSession(
            message: message,
            initialArtifact: artifact,
            loader: loader,
            loadTimeout: 0.03,
            recoveringDelay: 0.005
        )

        XCTAssertEqual(session.readerState, .preparedArtifact(artifact, placeholder: session.immediatePlaceholder))

        let task = Task { @MainActor in
            await session.loadOriginalEmail(
                for: session.loadRequest,
                missingSourceRecoveryPolicy: .keepRecoveringWhileActive
            )
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(session.readerState, .preparedArtifact(artifact, placeholder: session.immediatePlaceholder))

        _ = await task.value

        XCTAssertEqual(session.readerState, .preparedArtifact(artifact, placeholder: session.immediatePlaceholder))
        XCTAssertEqual(loader.ensureRequestCount, 1)
    }

    func testSessionWithoutInitialPayloadTransitionsRecoveringThenLoadedHTML() async throws {
        let html = "<html><body>Recovered full email</body></html>"
        let message = makeMessage(id: "recovering-load-task")
        let source = makeSource(
            html: html,
            sourceSignature: "loaded-source",
            sourceKind: .recoveredHTML,
            sourceLocation: .recoveredHTML
        )
        let loader = SessionStubOriginalEmailSourceLoader(
            responses: [source],
            delayNanoseconds: 40_000_000
        )
        let session = makeSession(
            message: message,
            initialArtifact: nil,
            loader: loader,
            loadTimeout: 0.1,
            recoveringDelay: 0.005
        )

        XCTAssertEqual(session.readerState, .loading(session.immediatePlaceholder))

        let task = Task { @MainActor in
            await session.loadOriginalEmail(
                for: session.loadRequest,
                missingSourceRecoveryPolicy: .keepRecoveringWhileActive
            )
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(session.readerState, .recovering(session.immediatePlaceholder))

        _ = await task.value

        guard case .loadedArtifact(let loadedArtifact, let placeholder) = session.readerState else {
            return XCTFail("Expected loaded artifact, got \(session.readerState)")
        }
        let expectedArtifact = makeArtifact(
            message: message,
            html: html,
            sourceSignature: "loaded-source",
            sourceKind: .recoveredHTML,
            sourceLocation: .recoveredHTML
        )
        XCTAssertEqual(loadedArtifact.body, expectedArtifact.body)
        XCTAssertEqual(loadedArtifact.sourceSignature, expectedArtifact.sourceSignature)
        XCTAssertEqual(loadedArtifact.renderSignature, expectedArtifact.renderSignature)
        XCTAssertEqual(placeholder, session.immediatePlaceholder)
        XCTAssertEqual(session.activeHTMLSourceSignature, "loaded-source")
        XCTAssertEqual(loader.ensureRequestCount, 1)
    }

    func testSessionRetryableFailureStoresPlaceholderAndRetryAdvancesGeneration() async {
        let message = makeMessage(id: "retryable-failure")
        let loader = SessionStubOriginalEmailSourceLoader(responses: [nil])
        let session = makeSession(
            message: message,
            initialArtifact: nil,
            loader: loader,
            loadTimeout: 0.01,
            recoveringDelay: 0.005
        )

        _ = await session.loadOriginalEmail(for: session.loadRequest)

        XCTAssertEqual(
            session.readerState,
            .retryableFailure(session.immediatePlaceholder, reason: "original_email_unavailable")
        )

        let generationBeforeRetry = session.loadingGeneration
        session.retry()

        XCTAssertEqual(session.readerState, .loading(session.immediatePlaceholder))
        XCTAssertEqual(session.loadingGeneration, generationBeforeRetry + 1)
    }

    func testSessionContentSourceNotificationReloadUsesSessionSourceSignature() async {
        let html = "<html><body>Loaded source</body></html>"
        let message = makeMessage(id: "content-source-notification")
        let loader = SessionStubOriginalEmailSourceLoader(
            responses: [
                makeSource(
                    html: html,
                    sourceSignature: "loaded-source",
                    sourceKind: .html,
                    sourceLocation: .messageFile
                )
            ]
        )
        let session = makeSession(
            message: message,
            initialArtifact: nil,
            loader: loader,
            loadTimeout: 0.1,
            recoveringDelay: 0.005
        )

        _ = await session.loadOriginalEmail(for: session.loadRequest)
        XCTAssertEqual(session.activeHTMLSourceSignature, "loaded-source")

        session.reloadIfContentSourceChanged(
            Notification(
                name: HTMLContentLoader.contentSourceDidChangeNotification,
                object: nil,
                userInfo: [
                    HTMLContentLoader.contentSourceDidChangeMessageIdUserInfoKey: message.id,
                    HTMLContentLoader.contentSourceDidChangeSourceSignatureUserInfoKey: "loaded-source"
                ]
            )
        )
        XCTAssertEqual(session.loadingGeneration, 0)

        session.reloadIfContentSourceChanged(
            Notification(
                name: HTMLContentLoader.contentSourceDidChangeNotification,
                object: nil,
                userInfo: [
                    HTMLContentLoader.contentSourceDidChangeMessageIdUserInfoKey: message.id,
                    HTMLContentLoader.contentSourceDidChangeSourceSignatureUserInfoKey: "new-source"
                ]
            )
        )
        XCTAssertEqual(session.loadingGeneration, 1)
    }

    func testReaderViewIsDrivenByOpenSession() {
        let message = makeMessage(id: "reader-view-message")
        let session = FullEmailOpenSession(
            message: message,
            request: OriginalEmailWarmRequest(
                messageId: message.id,
                bodyStorageURI: message.bodyStorageURI,
                bodyText: message.bodyTextValue,
                senderEmail: message.senderEmailValue,
                subject: message.subject
            ),
            initialArtifact: nil,
            immediatePlaceholder: FullEmailPlaceholder(message: message)
        )

        let readerView = FullEmailReaderView(session: session)

        XCTAssertEqual(readerView.session.messageObjectID, message.objectID)
        XCTAssertNil(readerView.session.initialArtifact)
        XCTAssertTrue(readerView.session.hasImmediateVisualSurface)
    }

    private func makeMessage(
        id: String,
        subject: String = "Subject",
        senderEmail: String = "sender@example.com",
        senderName: String? = "Sender",
        snippet: String = "Snippet",
        body: String = "Body"
    ) -> Message {
        MessageBuilder()
            .withId(id)
            .withSubject(subject)
            .withSender(email: senderEmail, name: senderName)
            .withSnippet(snippet)
            .withBody(body)
            .build(in: context)
    }

    private func makeArtifact(
        message: Message,
        html: String = "<html><body>Prepared</body></html>",
        sourceSignature: String? = nil,
        sourceKind: CanonicalEmailSourceKind = .html,
        sourceLocation: CanonicalEmailSourceLocation = .messageFile
    ) -> EmailReaderArtifact {
        EmailReaderArtifact(
            messageID: message.id,
            sourceSignature: sourceSignature ?? "sha256:\(message.id)",
            body: .html(html),
            metadata: EmailMetadataSnapshot(message: message),
            inlineAttachmentAvailabilitySignature: InlineCIDAttachmentAvailabilityFingerprint.make(
                html: html,
                message: message
            ),
            sourceKind: sourceKind,
            sourceLocation: sourceLocation,
            hasHTMLSource: true,
            producedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makePayload(
        messageId: String,
        checkoutAvailability: FullEmailOpenPayload.CheckoutAvailability = .ready
    ) -> FullEmailOpenPayload {
        FullEmailOpenPayload(
            messageId: messageId,
            sourceSignature: "sha256:\(messageId)",
            html: "<html><body>Prepared</body></html>",
            presentation: .html,
            sourceKind: .html,
            sourceLocation: .messageFile,
            hasHTMLSource: true,
            checkoutAvailability: checkoutAvailability
        )
    }

    private func makeSession(
        message: Message,
        initialArtifact: EmailReaderArtifact?,
        loader: any OriginalEmailSourceLoading,
        loadTimeout: TimeInterval,
        recoveringDelay: TimeInterval
    ) -> FullEmailOpenSession {
        FullEmailOpenSession(
            message: message,
            request: OriginalEmailWarmRequest(
                messageId: message.id,
                bodyStorageURI: message.bodyStorageURI,
                bodyText: message.bodyTextValue,
                senderEmail: message.senderEmailValue,
                subject: message.subject
            ),
            initialArtifact: initialArtifact,
            immediatePlaceholder: FullEmailPlaceholder(message: message),
            originalEmailSourceLoader: loader,
            originalEmailLoadTimeout: loadTimeout,
            recoveringDelay: recoveringDelay,
            onSourceLoaded: { _, _ in }
        )
    }

    private func makeSource(
        html: String,
        sourceSignature: String,
        sourceKind: CanonicalEmailSourceKind,
        sourceLocation: CanonicalEmailSourceLocation
    ) -> OriginalEmailSource {
        OriginalEmailSource(
            presentation: .html,
            html: html,
            plainText: nil,
            sourceKind: sourceKind,
            sourceLocation: sourceLocation,
            sourceSignature: sourceSignature,
            hasHTMLSource: true
        )
    }
}

@MainActor
private final class MockFullEmailReaderOpener: FullEmailOpening {
    struct PreparedPayloadRequest {
        let request: OriginalEmailWarmRequest
        let message: Message?
        let width: CGFloat?
    }

    struct PrepaintRequest {
        let request: OriginalEmailWarmRequest
        let message: Message
        let artifact: EmailReaderArtifact
        let width: CGFloat
    }

    struct PrewarmRequest {
        let message: Message
        let width: CGFloat?
    }

    let preparedArtifact: EmailReaderArtifact?
    let checkoutAvailability: FullEmailOpenPayload.CheckoutAvailability
    private(set) var preparedPayloadRequests: [PreparedPayloadRequest] = []
    private(set) var prepaintRequests: [PrepaintRequest] = []
    private(set) var prewarmedMessages: [PrewarmRequest] = []

    init(
        preparedArtifact: EmailReaderArtifact?,
        checkoutAvailability: FullEmailOpenPayload.CheckoutAvailability = .ready
    ) {
        self.preparedArtifact = preparedArtifact
        self.checkoutAvailability = checkoutAvailability
    }

    func preparedOpenArtifact(
        request: OriginalEmailWarmRequest,
        message: Message?,
        width: CGFloat?
    ) -> EmailReaderPreparedArtifact? {
        preparedPayloadRequests.append(
            PreparedPayloadRequest(
                request: request,
                message: message,
                width: width
            )
        )
        guard let preparedArtifact else {
            return nil
        }
        return EmailReaderPreparedArtifact(
            artifact: preparedArtifact,
            checkoutAvailability: checkoutAvailability
        )
    }

    func prepaintAfterExplicitOpen(
        request: OriginalEmailWarmRequest,
        message: Message,
        artifact: EmailReaderArtifact,
        width: CGFloat
    ) {
        prepaintRequests.append(
            PrepaintRequest(
                request: request,
                message: message,
                artifact: artifact,
                width: width
            )
        )
    }

    func prewarmOnOpen(message: Message, width: CGFloat?) {
        prewarmedMessages.append(PrewarmRequest(message: message, width: width))
    }
}

private final class SessionStubOriginalEmailSourceLoader: OriginalEmailSourceLoading, @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "SessionStubOriginalEmailSourceLoader.state")
    private var responses: [OriginalEmailSource?]
    private let delayNanoseconds: UInt64
    private var ensureCalls = 0

    init(responses: [OriginalEmailSource?], delayNanoseconds: UInt64 = 0) {
        self.responses = responses
        self.delayNanoseconds = delayNanoseconds
    }

    var ensureRequestCount: Int {
        stateQueue.sync { ensureCalls }
    }

    func loadOriginalEmailSource(
        messageId: String,
        bodyStorageURI: String?,
        bodyText: String?,
        senderEmail: String?,
        subject: String?,
        timeout: TimeInterval
    ) async -> OriginalEmailSource? {
        await ensureOriginalEmailAvailable(
            messageId: messageId,
            bodyStorageURI: bodyStorageURI,
            bodyText: bodyText,
            senderEmail: senderEmail,
            subject: subject
        )
    }

    func ensureOriginalEmailAvailable(
        messageId _: String,
        bodyStorageURI _: String?,
        bodyText _: String?,
        senderEmail _: String?,
        subject _: String?
    ) async -> OriginalEmailSource? {
        let response = stateQueue.sync { () -> OriginalEmailSource? in
            ensureCalls += 1
            return responses.isEmpty ? nil : responses.removeFirst()
        }

        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }

        return response
    }
}
