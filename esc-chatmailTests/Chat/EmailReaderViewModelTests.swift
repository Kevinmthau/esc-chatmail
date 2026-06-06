import CoreData
import CoreGraphics
import XCTest
@testable import esc_chatmail

@MainActor
final class EmailReaderViewModelTests: XCTestCase {
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

    func testResolveRoute_artifactHitCreatesPreparedSession() throws {
        let conversation = makeConversation()
        let message = makeMessage(
            id: "message-prepared",
            subject: "Prepared",
            conversation: conversation
        )
        let artifact = makeArtifact(message: message)
        let opener = MockEmailReaderViewModelFullEmailOpener(preparedArtifact: artifact)
        let viewModel = makeViewModel(
            message: message,
            conversation: conversation,
            source: .previewCard,
            opener: opener
        )

        let session = try XCTUnwrap(viewModel.session)
        XCTAssertTrue(session.message === message)
        XCTAssertEqual(session.initialArtifact, artifact)
        XCTAssertEqual(
            session.readerState,
            .preparedArtifact(artifact, placeholder: FullEmailPlaceholder(message: message))
        )
        XCTAssertEqual(opener.preparedPayloadRequests.count, 1)
        XCTAssertTrue(opener.prepaintRequests.isEmpty)
        XCTAssertTrue(opener.prewarmedMessages.isEmpty)
    }

    func testResolveRoute_payloadMissCreatesLoadingSessionAndStartsFallbackPrewarm() throws {
        let conversation = makeConversation()
        let message = makeMessage(
            id: "message-miss",
            subject: "Miss",
            conversation: conversation
        )
        let opener = MockEmailReaderViewModelFullEmailOpener(preparedArtifact: nil)
        let viewModel = makeViewModel(
            message: message,
            conversation: conversation,
            source: .bubbleAccessory,
            opener: opener
        )

        let session = try XCTUnwrap(viewModel.session)
        XCTAssertTrue(session.message === message)
        XCTAssertNil(session.initialArtifact)
        XCTAssertEqual(
            session.readerState,
            .loading(FullEmailPlaceholder(message: message))
        )
        XCTAssertEqual(session.immediatePlaceholder.subject, "Miss")
        XCTAssertTrue(session.hasImmediateVisualSurface)
        XCTAssertEqual(opener.preparedPayloadRequests.count, 1)
        XCTAssertTrue(opener.prepaintRequests.isEmpty)
        XCTAssertEqual(opener.prewarmedMessages.map(\.message.id), ["message-miss"])
        XCTAssertNil(opener.prewarmedMessages.first?.width)
    }

    func testReadableInitialModeFallsBackToOriginalUntilReadableReaderIsAvailable() {
        let conversation = makeConversation()
        let message = makeMessage(
            id: "message-readable",
            subject: "Readable",
            conversation: conversation
        )
        let opener = MockEmailReaderViewModelFullEmailOpener(preparedArtifact: nil)
        let route = EmailReaderRoute(
            messageObjectID: message.objectID,
            conversationObjectID: conversation.objectID,
            source: .debugOrFallback,
            initialMode: .readable
        )

        let viewModel = EmailReaderViewModel(
            route: route,
            viewContext: context,
            fullEmailReaderCoordinator: FullEmailReaderCoordinator(
                fullEmailOpener: opener
            )
        )

        XCTAssertEqual(viewModel.mode, .original)
        XCTAssertEqual(viewModel.availableModes, [.original])
    }

    private func makeViewModel(
        message: Message,
        conversation: Conversation,
        source: EmailReaderOpenSource,
        opener: MockEmailReaderViewModelFullEmailOpener
    ) -> EmailReaderViewModel {
        let route = EmailReaderRoute(
            messageObjectID: message.objectID,
            conversationObjectID: conversation.objectID,
            source: source,
            initialMode: .original
        )

        return EmailReaderViewModel(
            route: route,
            viewContext: context,
            fullEmailReaderCoordinator: FullEmailReaderCoordinator(
                fullEmailOpener: opener
            )
        )
    }

    private func makeConversation() -> Conversation {
        ConversationBuilder()
            .withDisplayName("Test Chat")
            .visible()
            .recentlyActive()
            .build(in: context)
    }

    private func makeMessage(
        id: String,
        subject: String,
        conversation: Conversation
    ) -> Message {
        MessageBuilder()
            .withId(id)
            .withSubject(subject)
            .withSender(email: "sender@example.com", name: "Sender")
            .withBody("\(subject) body")
            .inConversation(conversation)
            .build(in: context)
    }

    private func makeArtifact(message: Message) -> EmailReaderArtifact {
        let html = "<html><body>Prepared full email</body></html>"
        return EmailReaderArtifact(
            messageID: message.id,
            sourceSignature: "sha256:\(message.id)",
            body: .html(html),
            metadata: EmailMetadataSnapshot(message: message),
            inlineAttachmentAvailabilitySignature: InlineCIDAttachmentAvailabilityFingerprint.make(
                html: html,
                message: message
            ),
            sourceKind: .html,
            sourceLocation: .messageFile,
            hasHTMLSource: true,
            producedAt: Date(timeIntervalSince1970: 0)
        )
    }
}

@MainActor
private final class MockEmailReaderViewModelFullEmailOpener: FullEmailOpening {
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
    private(set) var preparedPayloadRequests: [PreparedPayloadRequest] = []
    private(set) var prepaintRequests: [PrepaintRequest] = []
    private(set) var prewarmedMessages: [PrewarmRequest] = []

    init(preparedArtifact: EmailReaderArtifact?) {
        self.preparedArtifact = preparedArtifact
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
            checkoutAvailability: .ready
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
