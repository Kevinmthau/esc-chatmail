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
        let payload = makePayload(messageId: "prepared-bounded-body-preview")
        let opener = MockFullEmailReaderOpener(preparedPayload: payload)
        let coordinator = FullEmailReaderCoordinator(
            fullEmailOpener: opener,
            widthProvider: { 390 }
        )

        let session = coordinator.openSession(for: message)

        XCTAssertEqual(session.state, .presentingPreparedPayload)
        XCTAssertEqual(session.immediatePlaceholder.previewText, "Prepared visible body")
        XCTAssertTrue(opener.prewarmedMessages.isEmpty)
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
