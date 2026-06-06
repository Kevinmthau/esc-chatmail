import XCTest
@testable import esc_chatmail

@MainActor
final class EmailReaderArtifactTests: XCTestCase {
    private var testStack: TestCoreDataStack!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
    }

    override func tearDown() {
        testStack = nil
        super.tearDown()
    }

    func testStableFingerprintOutputIsConsistent() {
        XCTAssertEqual(StableFingerprint.sha256Prefix("hello"), "2cf24dba5fb0a30e")
        XCTAssertEqual(StableFingerprint.sha256Prefix("hello", length: 8), "2cf24dba")
        XCTAssertEqual(StableFingerprint.sha256Prefix(nil), "nil")
    }

    func testPreparedHTMLPayloadCreatesReaderArtifact() {
        let message = makeMessage(id: "artifact-html")
        let html = "<html><body><img src=\"cid:image001@example.com\"></body></html>"
        let payload = FullEmailOpenPayload(
            messageId: message.id,
            sourceSignature: "sha256:artifact-html",
            html: html,
            presentation: .html,
            sourceKind: .html,
            sourceLocation: .messageFile,
            hasHTMLSource: true,
            checkoutAvailability: .warming
        )

        let artifact = payload.artifact(
            metadata: EmailMetadataSnapshot(message: message),
            message: message,
            producedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(artifact.messageID, message.id)
        XCTAssertEqual(artifact.sourceSignature, "sha256:artifact-html")
        XCTAssertEqual(artifact.body, .html(html))
        XCTAssertEqual(artifact.inlineAttachmentAvailabilitySignature, "cid:image001@example.com=missing")
        XCTAssertTrue(artifact.renderSignature.contains("body:html"))
        XCTAssertFalse(artifact.renderSignature.contains("width"))
    }

    func testPlainTextSourceCreatesReaderArtifact() throws {
        let message = makeMessage(id: "artifact-plain")
        let source = OriginalEmailSource(
            presentation: .nativePlainText,
            html: nil,
            plainText: "Plain fallback body",
            sourceKind: .plainText,
            sourceLocation: .plainText,
            sourceSignature: "plain-source",
            hasHTMLSource: false
        )

        let artifact = try XCTUnwrap(
            EmailReaderArtifact.make(
                messageID: message.id,
                source: source,
                metadata: EmailMetadataSnapshot(message: message),
                message: message,
                producedAt: Date(timeIntervalSince1970: 0)
            )
        )

        XCTAssertEqual(artifact.body, .plainText("Plain fallback body"))
        XCTAssertNil(artifact.inlineAttachmentAvailabilitySignature)
        XCTAssertEqual(artifact.sourceKind, .plainText)
        XCTAssertEqual(artifact.sourceLocation, .plainText)
        XCTAssertFalse(artifact.hasHTMLSource)
    }

    private func makeMessage(id: String) -> Message {
        MessageBuilder()
            .withId(id)
            .withSubject("Subject")
            .withSender(email: "sender@example.com", name: "Sender")
            .withBody("Body")
            .build(in: testStack.viewContext)
    }
}
