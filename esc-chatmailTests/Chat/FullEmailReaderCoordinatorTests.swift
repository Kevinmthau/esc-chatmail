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

    func testOpenSession_preparedPayloadCreatesPresentableSessionWithoutPrewarm() {
        let message = makeMessage(
            id: "prepared-message",
            subject: "Prepared subject",
            senderEmail: "sender@example.com",
            senderName: "Sender",
            snippet: "Prepared preview"
        )
        let payload = makePayload(messageId: "prepared-message")
        let opener = MockFullEmailReaderOpener(preparedPayload: payload)
        let coordinator = FullEmailReaderCoordinator(
            fullEmailOpener: opener,
            widthProvider: { 390 }
        )

        let session = coordinator.openSession(for: message)

        XCTAssertTrue(session.message === message)
        XCTAssertEqual(session.messageId, "prepared-message")
        XCTAssertEqual(session.messageObjectID, message.objectID)
        XCTAssertEqual(session.initialOpenPayload, payload)
        XCTAssertEqual(session.state, .presentingPreparedPayload)
        XCTAssertEqual(session.immediatePlaceholder.subject, "Prepared subject")
        XCTAssertTrue(session.hasImmediateVisualSurface)
        XCTAssertEqual(opener.preparedPayloadRequests.count, 1)
        XCTAssertEqual(opener.preparedPayloadRequests.first?.request.messageId, "prepared-message")
        XCTAssertEqual(opener.preparedPayloadRequests.first?.width, 390)
        XCTAssertTrue(opener.prewarmedMessages.isEmpty)
    }

    func testOpenSession_payloadMissCreatesPlaceholderAndStartsPrewarmFollowUp() {
        let message = makeMessage(
            id: "miss-message",
            subject: "Miss subject",
            senderEmail: "miss@example.com",
            senderName: "Miss Sender",
            snippet: "Miss snippet"
        )
        let opener = MockFullEmailReaderOpener(preparedPayload: nil)
        let coordinator = FullEmailReaderCoordinator(
            fullEmailOpener: opener,
            widthProvider: { 390 }
        )

        let session = coordinator.openSession(for: message)

        XCTAssertTrue(session.message === message)
        XCTAssertNil(session.initialOpenPayload)
        XCTAssertEqual(session.state, .presentingPlaceholder)
        XCTAssertEqual(session.immediatePlaceholder.subject, "Miss subject")
        XCTAssertEqual(session.immediatePlaceholder.senderDisplayText, "Miss Sender")
        XCTAssertEqual(session.immediatePlaceholder.previewText, "Miss snippet")
        XCTAssertTrue(session.hasImmediateVisualSurface)
        XCTAssertEqual(opener.preparedPayloadRequests.count, 1)
        XCTAssertEqual(opener.prewarmedMessages.map(\.id), ["miss-message"])
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
        let opener = MockFullEmailReaderOpener(preparedPayload: nil)
        let coordinator = FullEmailReaderCoordinator(fullEmailOpener: opener)

        let session = coordinator.openSession(for: message)

        XCTAssertNil(session.initialOpenPayload)
        XCTAssertEqual(session.immediatePlaceholder.subject, "No Subject")
        XCTAssertEqual(session.immediatePlaceholder.senderDisplayText, "fallback@example.com")
        XCTAssertEqual(session.immediatePlaceholder.previewText, "Body preview from the message")
        XCTAssertEqual(session.state, .presentingPlaceholder)
        XCTAssertTrue(session.hasImmediateVisualSurface)
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
            initialOpenPayload: nil,
            immediatePlaceholder: FullEmailPlaceholder(message: message)
        )

        let readerView = FullEmailReaderView(session: session)

        XCTAssertEqual(readerView.session.messageObjectID, message.objectID)
        XCTAssertNil(readerView.session.initialOpenPayload)
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

    private func makePayload(messageId: String) -> FullEmailOpenPayload {
        FullEmailOpenPayload(
            messageId: messageId,
            sourceSignature: "sha256:\(messageId)",
            html: "<html><body>Prepared</body></html>",
            presentation: .html,
            sourceKind: .html,
            sourceLocation: .messageFile,
            hasHTMLSource: true,
            checkoutAvailability: .ready
        )
    }
}

@MainActor
private final class MockFullEmailReaderOpener: FullEmailOpening {
    struct PreparedPayloadRequest {
        let request: OriginalEmailWarmRequest
        let message: Message?
        let width: CGFloat
    }

    let preparedPayload: FullEmailOpenPayload?
    private(set) var preparedPayloadRequests: [PreparedPayloadRequest] = []
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

    func prewarmOnOpen(message: Message) {
        prewarmedMessages.append(message)
    }
}
