import WebKit
import XCTest
@testable import esc_chatmail

/// Opening a warmed email and checking out its pre-rendered view do no body-size hashing or `cid:`
/// scanning on the main actor (architecture review 2026-11, `web-content-rendering#4`): the warm
/// computes the wrapped HTML's fingerprint and its referenced Content-IDs off the main actor, and
/// the prepared payload's keys, the checkout's key and the reader artifact's render signature are
/// built from them. The render signature they give is the one a cold open would compute.
@MainActor
final class FullEmailWebViewManagerMainThreadWorkTests: XCTestCase {
    private var messagesDirectory: URL!
    private var contentHandler: HTMLContentHandler!

    override func setUp() {
        super.setUp()
        messagesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FullEmailWebViewManagerMainThreadWorkTests-\(UUID().uuidString)"
        )
        contentHandler = HTMLContentHandler(messagesDirectory: messagesDirectory)
    }

    override func tearDown() {
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

    /// The one fingerprint stands in for the keys' own: a key made from the HTML equals one made
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
        XCTAssertEqual(
            FullEmailPreparedArtifactKey.make(messageId: "m", sourceSignature: "s", wrappedHTML: html).htmlFingerprint,
            fingerprint
        )
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
