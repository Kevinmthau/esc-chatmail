import WebKit
import XCTest
@testable import esc_chatmail

/// `FullEmailWebViewManager.adoptClosedReaderWebView` (architecture review 2026-11,
/// `web-content-rendering#2`, step 4): the web view of a reader that rendered live is kept as it
/// closes, and the next open of the same email checks it out, so the open itself renders nothing
/// off screen. The pool keeps it only where it would have made such a view itself.
@MainActor
final class FullEmailWebViewManagerReaderHandOverTests: XCTestCase {
    private var messagesDirectory: URL!
    private var contentHandler: HTMLContentHandler!

    override func setUp() {
        super.setUp()
        messagesDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FullEmailWebViewManagerReaderHandOverTests-\(UUID().uuidString)"
        )
        contentHandler = HTMLContentHandler(messagesDirectory: messagesDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: messagesDirectory)
        super.tearDown()
    }

    /// Revert-check: dropping `entry.didFinishInitialLoad = true` from `adoptClosedReaderWebView`
    /// makes the next checkout miss as `still_warming` and fails this.
    func testClosedReaderView_isTheNextOpensCheckout() async throws {
        let fixture = try await makeFixture()
        defer { fixture.manager.clear() }
        let webView = makeReaderWebView()
        XCTAssertEqual(
            fixture.manager.preparedOpenArtifact(request: fixture.request, message: nil, width: 390)?.checkoutAvailability,
            .warming,
            "Before: nothing to adopt"
        )

        XCTAssertTrue(fixture.handOver(webView))

        XCTAssertEqual(
            fixture.manager.preparedOpenArtifact(request: fixture.request, message: nil, width: 390)?.checkoutAvailability,
            .ready
        )

        XCTAssertTrue(fixture.manager.isWarmedForTesting(messageId: fixture.messageId))
        XCTAssertTrue(fixture.manager.webViewForTesting(messageId: fixture.messageId) === webView)
        let checkout = fixture.manager.checkout(
            messageId: fixture.messageId,
            sourceSignature: fixture.sourceSignature,
            wrappedHTML: fixture.html,
            message: nil,
            width: 390
        )
        XCTAssertTrue(checkout?.webView === webView)
    }

    /// Refused where the next open could not adopt it: no prepared payload, a payload for other
    /// HTML or another source, no width, or the message's entry already checked out.
    ///
    /// Revert-check: dropping `prepared.payload.html == wrappedHTML` from the guard fails the
    /// other-HTML case.
    func testHandOver_isRefusedWhereTheNextOpenCouldNotAdoptIt() async throws {
        let fixture = try await makeFixture()
        defer { fixture.manager.clear() }

        XCTAssertFalse(fixture.handOver(makeReaderWebView(), messageId: "not-warmed-\(UUID().uuidString)"))
        XCTAssertFalse(fixture.handOver(makeReaderWebView(), wrappedHTML: fixture.html + "<!-- other -->"))
        XCTAssertFalse(fixture.handOver(makeReaderWebView(), sourceSignature: "sha256:other"))
        XCTAssertFalse(fixture.handOver(makeReaderWebView(), width: 0))
        XCTAssertFalse(fixture.manager.hasPrerenderedWebViewEntryForTesting(messageId: fixture.messageId))

        let first = makeReaderWebView()
        XCTAssertTrue(fixture.handOver(first))
        XCTAssertNotNil(fixture.manager.checkout(
            messageId: fixture.messageId,
            sourceSignature: fixture.sourceSignature,
            wrappedHTML: fixture.html,
            message: nil,
            width: 390
        ))
        let second = makeReaderWebView()
        XCTAssertFalse(fixture.handOver(second), "A checked-out entry is the reader's")
        XCTAssertTrue(fixture.manager.webViewForTesting(messageId: fixture.messageId) === first)
    }

    /// An idle entry for the message is replaced, and torn down as an eviction would.
    func testHandOver_replacesAnIdleEntryOfTheMessage() async throws {
        let fixture = try await makeFixture()
        defer { fixture.manager.clear() }
        await fixture.manager.warm(request: fixture.request, message: nil, width: 390)
        let pooled = try XCTUnwrap(fixture.manager.webViewForTesting(messageId: fixture.messageId))
        let reader = makeReaderWebView(width: 412)

        XCTAssertTrue(fixture.handOver(reader, width: 412))

        XCTAssertTrue(fixture.manager.webViewForTesting(messageId: fixture.messageId) === reader)
        XCTAssertNil(pooled.navigationDelegate, "The replaced view was torn down")
    }

    /// A closed account keeps no reader's view.
    func testHandOver_isRefusedWhileAccountWorkIsClosed() async throws {
        let fixture = try await makeFixture()
        addTeardownBlock { @MainActor in
            FullEmailReaderAccountBoundaryRegistry.shared.reopenAccountWork()
        }
        await fixture.manager.clearForAccountTransition()

        XCTAssertFalse(fixture.handOver(makeReaderWebView()))
        fixture.manager.reopenAccountWork()
    }

    // MARK: - Fixtures

    private struct Fixture {
        let manager: FullEmailWebViewManager
        let messageId: String
        let request: OriginalEmailWarmRequest
        let html: String
        let sourceSignature: String

        @MainActor
        func handOver(
            _ webView: LayoutAwareWKWebView,
            messageId: String? = nil,
            sourceSignature: String? = nil,
            wrappedHTML: String? = nil,
            width: CGFloat = 390
        ) -> Bool {
            manager.adoptClosedReaderWebView(
                messageId: messageId ?? self.messageId,
                sourceSignature: sourceSignature ?? self.sourceSignature,
                wrappedHTML: wrappedHTML ?? html,
                message: nil,
                width: width,
                webView: webView,
                cidHandler: CIDSchemeHandler(message: nil)
            )
        }
    }

    /// A manager holding a prepared payload for one message, as a visible row's warm leaves it.
    private func makeFixture() async throws -> Fixture {
        let messageId = "hand-over-\(UUID().uuidString)"
        _ = contentHandler.saveHTML(
            "<!DOCTYPE html><html><body><h1>Hand over</h1><p>Reader content.</p></body></html>",
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
        await manager.warm(request: request, message: nil, width: nil)
        let prepared = try XCTUnwrap(manager.preparedOpenArtifact(request: request, message: nil, width: 390))
        guard case .html(let html) = prepared.artifact.body else {
            throw XCTSkip("Expected an HTML artifact")
        }
        XCTAssertFalse(manager.hasPrerenderedWebViewEntryForTesting(messageId: messageId), "Precondition")
        return Fixture(
            manager: manager,
            messageId: messageId,
            request: request,
            html: html,
            sourceSignature: prepared.artifact.sourceSignature
        )
    }

    private func makeReaderWebView(width: CGFloat = 390) -> LayoutAwareWKWebView {
        LayoutAwareWKWebView(
            frame: CGRect(x: 0, y: 0, width: width, height: 600),
            configuration: FullInteractiveEmailWebView.makeConfiguration(cidHandler: CIDSchemeHandler(message: nil))
        )
    }

    private func makeLoader() -> OriginalEmailSourceLoader {
        let recoveryService = HandOverNoRecovery()
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
private struct HandOverNoRecovery: HTMLContentRecovering {
    func recoverHTMLContent(messageId: String) async -> String? {
        nil
    }
}
