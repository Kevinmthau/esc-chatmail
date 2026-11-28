#if os(iOS)
import UIKit
import WebKit
import XCTest
@testable import esc_chatmail

/// A reader that rendered its email live offers its own web view to the pool as it is
/// dismantled, and only a view whose current content was confirmed painted and needs no reload
/// (architecture review 2026-11, `web-content-rendering#2`, step 4). A view the pool takes is the
/// pool's and is not scrubbed; any other is scrubbed as before.
@MainActor
final class FullEmailReaderHandOverTests: XCTestCase {
    private let html = "<html><body><p>Live reader</p></body></html>"
    private var window: UIWindow!

    override func setUpWithError() throws {
        try super.setUpWithError()
        window = try makeTestHostWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.isHidden = false
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        super.tearDown()
    }

    /// Revert-check: removing `|| coordinator.handOverLiveWebViewIfPossible(webView)` from
    /// `FullEmailReaderWebView.dismantleWebView` fails this.
    func testDismantle_paintedLiveReader_handsItsViewToThePool() throws {
        let adopter = RecordingHandOverAdopter(accepts: true)
        let (coordinator, webView, cidHandler) = makeLoadedReader(adopter: adopter)
        coordinator.webView(webView, didFinish: nil)

        FullEmailReaderWebView.dismantleUIView(webView, coordinator: coordinator)

        let handOver = try XCTUnwrap(adopter.handOvers.first)
        XCTAssertEqual(adopter.handOvers.count, 1)
        XCTAssertTrue(handOver.webView === webView)
        XCTAssertTrue(handOver.cidHandler === cidHandler)
        XCTAssertEqual(handOver.sourceSignature, "sha256:live")
        XCTAssertEqual(handOver.wrappedHTML, html)
        XCTAssertEqual(handOver.width, 390)
        XCTAssertTrue(coordinator.isInvalidatedForAccountTransitionForTesting)
        XCTAssertNotNil(webView.navigationDelegate, "The pool's view is not scrubbed")
    }

    /// A load that finished but whose paint was not confirmed yet is not offered, and is scrubbed.
    ///
    /// Revert-check: dropping `hasConfirmedPaintForCurrentLoad` from
    /// `handOverLiveWebViewIfPossible`'s guard fails this.
    func testDismantle_finishedButUnpaintedReader_isScrubbed() {
        let adopter = RecordingHandOverAdopter(accepts: true)
        let (coordinator, webView, _) = makeLoadedReader(adopter: adopter, paintConfirmer: PendingPaintConfirmer())
        coordinator.webView(webView, didFinish: nil)

        FullEmailReaderWebView.dismantleUIView(webView, coordinator: coordinator)

        XCTAssertTrue(adopter.handOvers.isEmpty)
        XCTAssertNil(webView.navigationDelegate)
    }

    /// A view still loading is not offered.
    func testDismantle_loadingReader_isScrubbed() {
        let adopter = RecordingHandOverAdopter(accepts: true)
        let (coordinator, webView, _) = makeLoadedReader(adopter: adopter)

        FullEmailReaderWebView.dismantleUIView(webView, coordinator: coordinator)

        XCTAssertTrue(adopter.handOvers.isEmpty)
        XCTAssertNil(webView.navigationDelegate)
    }

    /// Content the view does not show yet (it changed after the load) is not offered.
    func testDismantle_readerAwaitingAReload_isScrubbed() {
        let adopter = RecordingHandOverAdopter(accepts: true)
        let (coordinator, webView, _) = makeLoadedReader(adopter: adopter)
        coordinator.webView(webView, didFinish: nil)
        coordinator.updateParent(makeReader(adopter: adopter, html: html + "<!-- changed -->"))

        FullEmailReaderWebView.dismantleUIView(webView, coordinator: coordinator)

        XCTAssertTrue(adopter.handOvers.isEmpty)
        XCTAssertNil(webView.navigationDelegate)
    }

    /// A view the pool refuses is scrubbed as before.
    func testDismantle_refusedHandOver_isScrubbed() {
        let adopter = RecordingHandOverAdopter(accepts: false)
        let (coordinator, webView, _) = makeLoadedReader(adopter: adopter)
        coordinator.webView(webView, didFinish: nil)

        FullEmailReaderWebView.dismantleUIView(webView, coordinator: coordinator)

        XCTAssertEqual(adopter.handOvers.count, 1)
        XCTAssertNil(webView.navigationDelegate)
    }

    // MARK: - Fixtures

    private func makeReader(adopter: RecordingHandOverAdopter, html: String? = nil) -> FullEmailReaderWebView {
        let stack = TestCoreDataStack()
        let message = MessageBuilder()
            .withId("live-reader-\(UUID().uuidString)")
            .withSubject("Subject")
            .withSender(email: "sender@example.com", name: "Sender")
            .withBody("Body")
            .build(in: stack.viewContext)
        retainedStacks.append(stack)
        return FullEmailReaderWebView(
            htmlContent: html ?? self.html,
            sourceSignature: "sha256:live",
            readerWidth: 390,
            message: message,
            webViewAdoptionProvider: adopter
        )
    }

    private var retainedStacks: [TestCoreDataStack] = []

    /// A live reader whose load has started in a shown window, with a paint confirmer that answers
    /// at once, so a `didFinish` confirms the paint.
    private func makeLoadedReader(
        adopter: RecordingHandOverAdopter,
        paintConfirmer: FullEmailReaderPaintConfirming = ImmediatePaintConfirmer()
    ) -> (FullEmailReaderWebView.Coordinator, LayoutAwareWKWebView, CIDSchemeHandler) {
        let reader = makeReader(adopter: adopter)
        let coordinator = FullEmailReaderWebView.Coordinator(reader, paintConfirmer: paintConfirmer)
        let cidHandler = CIDSchemeHandler(message: reader.message)
        coordinator.cidHandler = cidHandler
        let webView = LayoutAwareWKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600),
            configuration: FullInteractiveEmailWebView.makeConfiguration(cidHandler: cidHandler)
        )
        webView.navigationDelegate = coordinator
        window.addSubview(webView)
        addTeardownBlock { @MainActor in
            webView.removeFromSuperview()
        }
        coordinator.loadContentIfReady(in: webView)
        XCTAssertEqual(coordinator.lastLoadedContent, reader.htmlContent, "Precondition: the reader loaded")
        return (coordinator, webView, cidHandler)
    }
}

/// Never answers, as a snapshot still in flight.
private struct PendingPaintConfirmer: FullEmailReaderPaintConfirming {
    func confirmPaint(in webView: WKWebView, completion: @escaping (Bool) -> Void) {}
}

private struct ImmediatePaintConfirmer: FullEmailReaderPaintConfirming {
    func confirmPaint(in webView: WKWebView, completion: @escaping (Bool) -> Void) {
        completion(true)
    }
}

@MainActor
private final class RecordingHandOverAdopter: FullEmailWebViewAdopting {
    struct HandOver {
        let messageId: String
        let sourceSignature: String
        let wrappedHTML: String
        let width: CGFloat
        let webView: LayoutAwareWKWebView
        let cidHandler: CIDSchemeHandler
    }

    private let accepts: Bool
    private(set) var handOvers: [HandOver] = []

    init(accepts: Bool) {
        self.accepts = accepts
    }

    func checkout(
        messageId: String,
        sourceSignature: String?,
        wrappedHTML: String,
        message: Message?,
        width: CGFloat
    ) -> FullEmailWebViewManager.Checkout? {
        nil
    }

    func checkin(messageId: String, webView: WKWebView) -> Bool {
        false
    }

    func discard(messageId: String, webView: WKWebView) {}

    func adoptClosedReaderWebView(
        messageId: String,
        sourceSignature: String,
        wrappedHTML: String,
        message: Message?,
        width: CGFloat,
        webView: LayoutAwareWKWebView,
        cidHandler: CIDSchemeHandler
    ) -> Bool {
        handOvers.append(HandOver(
            messageId: messageId,
            sourceSignature: sourceSignature,
            wrappedHTML: wrappedHTML,
            width: width,
            webView: webView,
            cidHandler: cidHandler
        ))
        return accepts
    }
}
#endif
