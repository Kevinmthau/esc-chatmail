import CoreData
import WebKit
import XCTest
@testable import esc_chatmail

/// Opening a warmed email, checking out its pre-rendered view and the prepaint the open asks for do
/// no body-size hashing or `cid:` scanning on the main actor (architecture review 2026-11,
/// `web-content-rendering#4`): the warm
/// computes the wrapped HTML's fingerprint and its referenced Content-IDs off the main actor, and
/// the prepared payload's keys, the checkout's key and the reader artifact's render signature are
/// built from them. The render signature they give is the one a cold open would compute.
@MainActor
final class FullEmailWebViewManagerMainThreadWorkTests: XCTestCase {
    private var messagesDirectory: URL!
    private var contentHandler: HTMLContentHandler!
    private var testStack: TestCoreDataStack!
    /// Main-queue, so the suite's main-actor bodies touch it on its queue.
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        context = testStack.makeMainQueueViewContext()
        messagesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FullEmailWebViewManagerMainThreadWorkTests-\(UUID().uuidString)"
        )
        contentHandler = HTMLContentHandler(messagesDirectory: messagesDirectory)
    }

    override func tearDown() {
        context = nil
        testStack = nil
        try? FileManager.default.removeItem(at: messagesDirectory)
        super.tearDown()
    }

    /// The counts are read around synchronous main-actor calls only, so nothing else can run on
    /// the main thread between them.
    ///
    /// Revert-check: building `checkout`'s key from `wrappedHTML` again
    /// (`FullEmailWebViewPreRenderKey.make(…, wrappedHTML: wrappedHTML, …)`), or giving
    /// `FullEmailOpenPayload.artifact` no `bodyFingerprint`, fails this.
    func testOpenAndCheckoutOfAWarmedEmail_hashAndScanNothingOnTheMainThread() async throws {
        let messageId = "main-thread-work-\(UUID().uuidString)"
        _ = contentHandler.saveHTML(
            #"<!DOCTYPE html><html><body><p>Warmed</p><img src="cid:logo@example.com"></body></html>"#,
            for: messageId
        )
        let request = OriginalEmailWarmRequest(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Body \(messageId)",
            senderEmail: "sender@example.com",
            subject: "Subject"
        )
        let manager = FullEmailWebViewManager(loader: makeLoader())
        defer { manager.clear() }
        await manager.warm(request: request, message: nil, width: 390)
        manager.markInitialLoadFinishedForTesting(messageId: messageId)

        let hashesBefore = ReaderContentFingerprint.mainThreadComputationCountForTesting
        let scansBefore = InlineCIDAttachmentAvailabilityFingerprint.mainThreadScanCountForTesting

        let prepared = try XCTUnwrap(manager.preparedOpenArtifact(request: request, message: nil, width: 390))
        guard case .html(let html) = prepared.artifact.body else {
            return XCTFail("Expected an HTML artifact")
        }
        let checkout = manager.checkout(
            messageId: messageId,
            sourceSignature: prepared.artifact.sourceSignature,
            wrappedHTML: html,
            message: nil,
            width: 390
        )

        XCTAssertEqual(ReaderContentFingerprint.mainThreadComputationCountForTesting - hashesBefore, 0)
        XCTAssertEqual(InlineCIDAttachmentAvailabilityFingerprint.mainThreadScanCountForTesting - scansBefore, 0)
        XCTAssertEqual(prepared.checkoutAvailability, .ready)
        XCTAssertNotNil(checkout, "The checkout still matches the warmed view")

        // A cold open's artifact, with every fingerprint computed from the HTML: the prepared one
        // must render the same, or the reader would reload an adopted view.
        let cold = try XCTUnwrap(EmailReaderArtifact.make(
            messageID: messageId,
            source: OriginalEmailSource(
                presentation: .html,
                html: html,
                plainText: nil,
                sourceKind: prepared.artifact.sourceKind,
                sourceLocation: prepared.artifact.sourceLocation,
                sourceSignature: prepared.artifact.sourceSignature,
                hasHTMLSource: prepared.artifact.hasHTMLSource
            ),
            metadata: prepared.artifact.metadata,
            message: nil
        ))
        XCTAssertEqual(prepared.artifact.renderSignature, cold.renderSignature)
        XCTAssertEqual(
            prepared.artifact.inlineAttachmentAvailabilitySignature,
            cold.inlineAttachmentAvailabilitySignature
        )
    }

    /// The one fingerprint stands in for the key's own: a key made from the HTML equals one made
    /// from its fingerprint.
    func testKeysFromTheFingerprint_equalKeysFromTheHTML() {
        let html = "<html><body>Same</body></html>"
        let fingerprint = ReaderContentFingerprint.make(html)

        XCTAssertEqual(
            FullEmailWebViewPreRenderKey.make(
                messageId: "m", sourceSignature: "s", wrappedHTML: html, cidAvailabilityFingerprint: "c", width: 390
            ),
            FullEmailWebViewPreRenderKey.make(
                messageId: "m", sourceSignature: "s", htmlFingerprint: fingerprint, cidAvailabilityFingerprint: "c", width: 390
            )
        )
    }

    /// The warm works the wrapped HTML's fingerprint and `cid:` set out off the main actor and
    /// hands them to the payload, which would otherwise work them out itself, on the main actor.
    ///
    /// Revert-check: dropping `htmlFingerprint:` and `referencedInlineContentIDs:` from
    /// `FullEmailWebViewManager.makePayload` fails this.
    /// HONEST SCOPE: counted around an `await`, so main-thread work of anything else in the process
    /// during the warm would count too; nothing else in this suite hashes a reader body.
    func testWarm_computesTheTokensOffTheMainThread() async throws {
        let (request, _) = try makeWarmableMessage()
        let manager = FullEmailWebViewManager(loader: makeLoader())
        defer { manager.clear() }
        let hashesBefore = ReaderContentFingerprint.mainThreadComputationCountForTesting
        let scansBefore = InlineCIDAttachmentAvailabilityFingerprint.mainThreadScanCountForTesting

        await manager.warm(request: request, message: nil, width: nil)

        XCTAssertTrue(manager.hasPreparedPayloadForTesting(messageId: request.messageId), "Precondition: the warm stored its payload")
        XCTAssertEqual(ReaderContentFingerprint.mainThreadComputationCountForTesting - hashesBefore, 0)
        XCTAssertEqual(InlineCIDAttachmentAvailabilityFingerprint.mainThreadScanCountForTesting - scansBefore, 0)
    }

    /// A prepaint of the warmed email's own artifact takes the prepared payload's fingerprint and
    /// `cid:` set instead of working them out again on the main actor.
    ///
    /// Revert-check: removing the prepared-payload branch from
    /// `FullEmailWebViewManager.prepaintPayload(for:html:)` fails this.
    func testPrepaintOfAWarmedEmail_reusesTheWarmsTokens() async throws {
        let (request, message) = try makeWarmableMessage()
        let manager = FullEmailWebViewManager(loader: makeLoader())
        defer { manager.clear() }
        await manager.warm(request: request, message: message, width: 390)
        let prepared = try XCTUnwrap(manager.preparedOpenArtifact(request: request, message: message, width: 390))
        let hashesBefore = ReaderContentFingerprint.mainThreadComputationCountForTesting
        let scansBefore = InlineCIDAttachmentAvailabilityFingerprint.mainThreadScanCountForTesting

        manager.prepaintAfterExplicitOpen(request: request, message: message, artifact: prepared.artifact, width: 390)

        XCTAssertEqual(ReaderContentFingerprint.mainThreadComputationCountForTesting - hashesBefore, 0)
        XCTAssertEqual(InlineCIDAttachmentAvailabilityFingerprint.mainThreadScanCountForTesting - scansBefore, 0)
        XCTAssertTrue(manager.hasPrerenderedWebViewEntryForTesting(messageId: request.messageId), "The view is still kept")
    }

    /// While the reader holds the message's view, a prepaint returns before it builds a payload,
    /// even for content the prepared payload does not hold: it has nothing to prepaint, and every
    /// open of an adopted view asks for one.
    ///
    /// Revert-check: removing the checked-out return at the top of
    /// `prepaintAfterExplicitOpen(request:message:artifact:width:expectedAccountGeneration:)`
    /// fails this.
    func testPrepaintWhileTheReaderHoldsTheView_worksNothingOut() async throws {
        let (request, message) = try makeWarmableMessage()
        let manager = FullEmailWebViewManager(loader: makeLoader())
        defer { manager.clear() }
        await manager.warm(request: request, message: message, width: 390)
        manager.markInitialLoadFinishedForTesting(messageId: request.messageId)
        let prepared = try XCTUnwrap(manager.preparedOpenArtifact(request: request, message: message, width: 390))
        guard case .html(let html) = prepared.artifact.body else {
            return XCTFail("Expected an HTML artifact")
        }
        XCTAssertNotNil(manager.checkout(
            messageId: request.messageId,
            sourceSignature: prepared.artifact.sourceSignature,
            wrappedHTML: html,
            message: message,
            width: 390
        ), "Precondition: the reader holds the view")
        let otherContent = try XCTUnwrap(EmailReaderArtifact.make(
            messageID: request.messageId,
            source: OriginalEmailSource(
                presentation: .html,
                html: html + "<!-- changed -->",
                plainText: nil,
                sourceKind: prepared.artifact.sourceKind,
                sourceLocation: prepared.artifact.sourceLocation,
                sourceSignature: prepared.artifact.sourceSignature,
                hasHTMLSource: prepared.artifact.hasHTMLSource
            ),
            metadata: prepared.artifact.metadata,
            message: message
        ))
        let hashesBefore = ReaderContentFingerprint.mainThreadComputationCountForTesting
        let scansBefore = InlineCIDAttachmentAvailabilityFingerprint.mainThreadScanCountForTesting

        manager.prepaintAfterExplicitOpen(request: request, message: message, artifact: otherContent, width: 390)

        XCTAssertEqual(ReaderContentFingerprint.mainThreadComputationCountForTesting - hashesBefore, 0)
        XCTAssertEqual(InlineCIDAttachmentAvailabilityFingerprint.mainThreadScanCountForTesting - scansBefore, 0)
    }

    /// A stored message and its warm request, with a body in the suite's own directory.
    private func makeWarmableMessage() throws -> (OriginalEmailWarmRequest, Message) {
        let messageId = "main-thread-work-\(UUID().uuidString)"
        _ = contentHandler.saveHTML(
            #"<!DOCTYPE html><html><body><p>Warmed</p><img src="cid:logo@example.com"></body></html>"#,
            for: messageId
        )
        let message = MessageBuilder()
            .withId(messageId)
            .build(in: context)
        try context.save()
        let request = OriginalEmailWarmRequest(
            messageId: messageId,
            bodyStorageURI: nil,
            bodyText: "Body \(messageId)",
            senderEmail: "sender@example.com",
            subject: "Subject"
        )
        return (request, message)
    }

    private func makeLoader() -> OriginalEmailSourceLoader {
        let recoveryService = MainThreadWorkNoRecovery()
        return OriginalEmailSourceLoader(
            canonicalContentLoader: CanonicalEmailContentLoader(
                contentHandler: contentHandler,
                recoveryService: recoveryService
            ),
            htmlContentLoader: HTMLContentLoader(
                contentHandler: contentHandler,
                sanitizer: .shared,
                remoteImageAttachmentFallback: HTMLRemoteImageAttachmentFallback(
                    requestExecutor: { _ in throw URLError(.unsupportedURL) }
                ),
                recoveryService: recoveryService
            ),
            renderedMessageCache: RenderedMessageCache()
        )
    }
}

/// Recovers nothing: these tests use only HTML saved to their own directory.
private struct MainThreadWorkNoRecovery: HTMLContentRecovering {
    func recoverHTMLContent(messageId: String) async -> String? {
        nil
    }
}
