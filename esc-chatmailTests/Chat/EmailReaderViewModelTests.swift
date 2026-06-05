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

    func testResolveRoute_payloadHitCreatesPreparedSessionAndStartsExplicitPrepaint() throws {
        let conversation = makeConversation()
        let message = makeMessage(
            id: "message-prepared",
            subject: "Prepared",
            conversation: conversation
        )
        let payload = makePayload(messageId: "message-prepared")
        let opener = MockEmailReaderViewModelFullEmailOpener(preparedPayload: payload)
        let viewModel = makeViewModel(
            message: message,
            conversation: conversation,
            source: .previewCard,
            opener: opener
        )

        let session = try XCTUnwrap(viewModel.session)
        XCTAssertTrue(session.message === message)
        XCTAssertEqual(session.initialOpenPayload, payload)
        XCTAssertEqual(
            session.readerState,
            .preparedHTML(payload, placeholder: FullEmailPlaceholder(message: message))
        )
        XCTAssertEqual(opener.preparedPayloadRequests.count, 1)
        XCTAssertEqual(opener.prepaintRequests.count, 1)
        XCTAssertEqual(opener.prepaintRequests.first?.request.messageId, "message-prepared")
        XCTAssertEqual(opener.prepaintRequests.first?.message.id, "message-prepared")
        XCTAssertEqual(opener.prepaintRequests.first?.payload, payload)
        XCTAssertTrue(opener.prewarmedMessages.isEmpty)
    }

    func testResolveRoute_payloadMissCreatesLoadingSessionAndStartsFallbackPrewarm() throws {
        let conversation = makeConversation()
        let message = makeMessage(
            id: "message-miss",
            subject: "Miss",
            conversation: conversation
        )
        let opener = MockEmailReaderViewModelFullEmailOpener(preparedPayload: nil)
        let viewModel = makeViewModel(
            message: message,
            conversation: conversation,
            source: .bubbleAccessory,
            opener: opener
        )

        let session = try XCTUnwrap(viewModel.session)
        XCTAssertTrue(session.message === message)
        XCTAssertNil(session.initialOpenPayload)
        XCTAssertEqual(
            session.readerState,
            .loading(FullEmailPlaceholder(message: message))
        )
        XCTAssertEqual(session.immediatePlaceholder.subject, "Miss")
        XCTAssertTrue(session.hasImmediateVisualSurface)
        XCTAssertEqual(opener.preparedPayloadRequests.count, 1)
        XCTAssertTrue(opener.prepaintRequests.isEmpty)
        XCTAssertEqual(opener.prewarmedMessages.map(\.id), ["message-miss"])
    }

    func testReadableInitialModeFallsBackToOriginalUntilReadableReaderIsAvailable() {
        let conversation = makeConversation()
        let message = makeMessage(
            id: "message-readable",
            subject: "Readable",
            conversation: conversation
        )
        let opener = MockEmailReaderViewModelFullEmailOpener(preparedPayload: nil)
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
                fullEmailOpener: opener,
                widthProvider: { 390 }
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
                fullEmailOpener: opener,
                widthProvider: { 390 }
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

    private func makePayload(messageId: String) -> FullEmailOpenPayload {
        FullEmailOpenPayload(
            messageId: messageId,
            sourceSignature: "sha256:\(messageId)",
            html: "<html><body>Prepared full email</body></html>",
            presentation: .html,
            sourceKind: .html,
            sourceLocation: .messageFile,
            hasHTMLSource: true,
            checkoutAvailability: .ready
        )
    }
}

@MainActor
private final class MockEmailReaderViewModelFullEmailOpener: FullEmailOpening {
    struct PreparedPayloadRequest {
        let request: OriginalEmailWarmRequest
        let message: Message?
        let width: CGFloat
    }

    struct PrepaintRequest {
        let request: OriginalEmailWarmRequest
        let message: Message
        let payload: FullEmailOpenPayload
        let width: CGFloat
    }

    let preparedPayload: FullEmailOpenPayload?
    private(set) var preparedPayloadRequests: [PreparedPayloadRequest] = []
    private(set) var prepaintRequests: [PrepaintRequest] = []
    private(set) var prewarmedMessages: [Message] = []

    init(preparedPayload: FullEmailOpenPayload?) {
        self.preparedPayload = preparedPayload
    }

    func preparedOpenPayload(
        request: OriginalEmailWarmRequest,
        message: Message?,
        width: CGFloat
    ) -> FullEmailOpenPayload? {
        preparedPayloadRequests.append(
            PreparedPayloadRequest(
                request: request,
                message: message,
                width: width
            )
        )
        return preparedPayload
    }

    func prepaintAfterExplicitOpen(
        request: OriginalEmailWarmRequest,
        message: Message,
        payload: FullEmailOpenPayload,
        width: CGFloat
    ) {
        prepaintRequests.append(
            PrepaintRequest(
                request: request,
                message: message,
                payload: payload,
                width: width
            )
        )
    }

    func prewarmOnOpen(message: Message) {
        prewarmedMessages.append(message)
    }
}
