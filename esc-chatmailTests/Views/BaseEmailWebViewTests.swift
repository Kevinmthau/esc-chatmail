#if os(iOS)
import XCTest
import UIKit
import WebKit
@testable import esc_chatmail

@MainActor
final class BaseEmailWebViewTests: XCTestCase {
    private var coreDataStack: TestCoreDataStack!

    override func setUp() {
        super.setUp()
        coreDataStack = TestCoreDataStack()
    }

    override func tearDown() {
        coreDataStack = nil
        super.tearDown()
    }

    func testUpdateParentRefreshesCIDHandlerMessage() {
        let originalMessage = makeMessage(id: "message-a")
        let updatedMessage = makeMessage(id: "message-b")
        let originalView = makeWebView(message: originalMessage)
        let updatedView = makeWebView(message: updatedMessage)
        let coordinator = BaseEmailWebView.Coordinator(originalView)
        let cidHandler = CIDSchemeHandler(message: originalMessage)
        coordinator.cidHandler = cidHandler

        coordinator.updateParent(updatedView)

        XCTAssertTrue(coordinator.parent.message === updatedMessage)
        XCTAssertTrue(cidHandler.message === updatedMessage)
    }

    func testDraftInlineResourceChangeUpdatesHandlerAndReloadsUnchangedHTML() {
        var originalView = makeWebView(message: nil, html: "<img src=\"cid:logo@example.com\">")
        originalView.inlineResources = [.init(contentID: "logo@example.com", localURL: "Attachments/first.png", mimeType: "image/png")]
        var updatedView = originalView
        updatedView.inlineResources = [.init(contentID: "logo@example.com", localURL: "Attachments/second.png", mimeType: "image/png")]
        let coordinator = BaseEmailWebView.Coordinator(originalView)
        let handler = CIDSchemeHandler(message: nil, localResources: originalView.inlineResources)
        coordinator.cidHandler = handler
        coordinator.recordLoadedSignature()

        coordinator.updateParent(updatedView)

        XCTAssertEqual(handler.localResources, updatedView.inlineResources)
        XCTAssertTrue(coordinator.needsReload)
    }

    func testCoordinatorNeedsReloadWhenMessageIdentityChangesForSameHTML() {
        let originalMessage = makeMessage(id: "message-a")
        let updatedMessage = makeMessage(id: "message-b")
        let originalView = makeWebView(message: originalMessage)
        let updatedView = makeWebView(message: updatedMessage)
        let coordinator = BaseEmailWebView.Coordinator(originalView)

        coordinator.recordLoadedSignature()
        XCTAssertFalse(coordinator.needsReload)

        coordinator.updateParent(updatedView)

        XCTAssertTrue(coordinator.needsReload)
    }

    func testCoordinatorNeedsReloadWhenPreviewDarkModeToggles() {
        let message = makeMessage(id: "message-dark-toggle")
        let lightView = makeWebView(message: message, isDarkMode: false)
        let darkView = makeWebView(message: message, isDarkMode: true)
        let coordinator = BaseEmailWebView.Coordinator(lightView)

        coordinator.recordLoadedSignature()
        XCTAssertFalse(coordinator.needsReload)

        coordinator.updateParent(darkView)

        XCTAssertTrue(coordinator.needsReload)
    }

    func testPendingReload_multipleUpdatesDuringLoad_loadsOnlyLatestContentAfterFinish() {
        // Revert-check: remove pending-reload tracking from BaseEmailWebView.Coordinator.loadContentIfReady.
        let originalView = makeWebView(message: nil, html: "<p>Original</p>")
        let coordinator = BaseEmailWebView.Coordinator(originalView)
        let webView = RecordingPreviewWebView()
        coordinator.loadContentIfReady(in: webView)

        coordinator.updateParent(makeWebView(message: nil, html: "<p>Intermediate</p>"))
        coordinator.loadContentIfReady(in: webView)
        coordinator.updateParent(makeWebView(message: nil, html: "<p>Latest</p>"))
        coordinator.loadContentIfReady(in: webView)
        XCTAssertEqual(webView.loadedHTML, ["<p>Original</p>"])

        coordinator.webView(webView, didFinish: nil)

        XCTAssertEqual(webView.loadedHTML, ["<p>Original</p>", "<p>Latest</p>"])
        coordinator.webView(webView, didFinish: nil)
        XCTAssertEqual(webView.loadedHTML.count, 2)
        XCTAssertFalse(coordinator.needsReload)
    }

    func testPendingReload_appearanceChangesDuringLoad_reloadsAfterFinish() {
        // Revert-check: remove pending-reload tracking from BaseEmailWebView.Coordinator.loadContentIfReady.
        let originalView = makeWebView(message: nil, isDarkMode: false)
        let coordinator = BaseEmailWebView.Coordinator(originalView)
        let webView = RecordingPreviewWebView()
        coordinator.loadContentIfReady(in: webView)

        coordinator.updateParent(makeWebView(message: nil, isDarkMode: true))
        coordinator.loadContentIfReady(in: webView)
        XCTAssertEqual(webView.loadedHTML.count, 1)

        coordinator.webView(webView, didFinish: nil)

        XCTAssertEqual(webView.loadedHTML, [originalView.htmlContent, originalView.htmlContent])
        XCTAssertFalse(coordinator.needsReload)
    }

    func testPendingReload_navigationFails_loadsLatestContentWithoutRetryingItsFailure() {
        // Revert-check: remove pending-reload tracking from BaseEmailWebView.Coordinator.loadContentIfReady.
        assertPendingReloadAfterFailure(isProvisional: false)
    }

    func testPendingReload_provisionalNavigationFails_loadsLatestContentWithoutRetryingItsFailure() {
        // Revert-check: remove pending-reload tracking from BaseEmailWebView.Coordinator.loadContentIfReady.
        assertPendingReloadAfterFailure(isProvisional: true)
    }

    func testPendingReload_latestInputReturnsToOriginal_doesNotReloadAfterFinish() {
        // HONEST SCOPE: the old implementation also passes; this guards against a sticky pending flag.
        let originalView = makeWebView(message: nil)
        let coordinator = BaseEmailWebView.Coordinator(originalView)
        let webView = RecordingPreviewWebView()
        coordinator.loadContentIfReady(in: webView)

        coordinator.updateParent(makeWebView(message: nil, html: "<p>Superseded</p>"))
        coordinator.loadContentIfReady(in: webView)
        coordinator.updateParent(originalView)
        coordinator.loadContentIfReady(in: webView)
        coordinator.webView(webView, didFinish: nil)

        XCTAssertEqual(webView.loadedHTML, [originalView.htmlContent])
        XCTAssertFalse(coordinator.needsReload)
    }

    func testPendingReload_unchangedFailedInput_doesNotAutomaticallyRetry() {
        // HONEST SCOPE: the old implementation also passes; failure alone must not trigger a new load.
        for isProvisional in [false, true] {
            let originalView = makeWebView(message: nil)
            let coordinator = BaseEmailWebView.Coordinator(originalView)
            let webView = RecordingPreviewWebView()
            coordinator.loadContentIfReady(in: webView)
            coordinator.updateParent(originalView)
            coordinator.loadContentIfReady(in: webView)

            failNavigation(coordinator, in: webView, isProvisional: isProvisional)

            XCTAssertEqual(webView.loadedHTML, [originalView.htmlContent])
            XCTAssertTrue(coordinator.needsReload)
        }
    }

    // Revert-check: fails if `BaseEmailWebView.Coordinator.webViewWebContentProcessDidTerminate`
    // stops reloading (the preview stays blank: `needsReload` compares only the recorded
    // signature), or reloads on every termination (drop its
    // `admitsReloadAfterWebContentTermination` guard: a second termination before the reload
    // finished, and every update after it, reload a page that crashes WebKit as it loads).
    func testWebContentTermination_beforeTheReloadFinished_reloadsOnlyOnce() {
        let view = makeWebView(message: nil, html: "<p>Preview</p>")
        let coordinator = BaseEmailWebView.Coordinator(view)
        let webView = RecordingPreviewWebView()
        coordinator.loadContentIfReady(in: webView)
        coordinator.webView(webView, didFinish: nil)

        coordinator.webViewWebContentProcessDidTerminate(webView)
        XCTAssertEqual(webView.loadedHTML, ["<p>Preview</p>", "<p>Preview</p>"])
        XCTAssertTrue(webView.loadedRequests.isEmpty, "Nothing is loaded by URL, the base URL included")

        coordinator.webViewWebContentProcessDidTerminate(webView)
        coordinator.updateParent(view)
        coordinator.loadContentIfReady(in: webView)

        XCTAssertEqual(webView.loadedHTML.count, 2)
        XCTAssertFalse(coordinator.needsReload)
    }

    // Revert-check: fails if the preview's `didFinish` stops calling
    // `recordDisplayedAfterWebContentTermination` (a preview killed again after it recovered stays
    // blank), or if `admitsReloadAfterWebContentTermination` loses its
    // `maximumWebContentTerminationReloads` bound (a page that loads and then crashes reloads
    // without end).
    func testWebContentTermination_afterEachReloadFinished_reloadsAgainUpToTheCap() {
        let view = makeWebView(message: nil, html: "<p>Preview</p>")
        let coordinator = BaseEmailWebView.Coordinator(view)
        let webView = RecordingPreviewWebView()
        coordinator.loadContentIfReady(in: webView)
        coordinator.webView(webView, didFinish: nil)
        let cap = EmailWebViewLoadCoordination.maximumWebContentTerminationReloads

        for _ in 0..<cap {
            coordinator.webViewWebContentProcessDidTerminate(webView)
            coordinator.webView(webView, didFinish: nil)
        }
        XCTAssertEqual(webView.loadedHTML.count, 1 + cap)

        coordinator.webViewWebContentProcessDidTerminate(webView)
        coordinator.loadContentIfReady(in: webView)

        XCTAssertEqual(webView.loadedHTML.count, 1 + cap)
        XCTAssertFalse(coordinator.needsReload)
    }

    // Revert-check: fails if the preview's `didFail` or `didFailProvisionalNavigation` loses its
    // `isWebContentProcessTerminationError` guard (each reverted on its own): the failure resets
    // the signature the termination's reload recorded, and the next update loads it again.
    func testWebContentTermination_failureReportedForTheDeadNavigation_doesNotRearmAReload() {
        for isProvisional in [false, true] {
            let coordinator = BaseEmailWebView.Coordinator(makeWebView(message: nil))
            let webView = RecordingPreviewWebView()
            coordinator.loadContentIfReady(in: webView)
            coordinator.webViewWebContentProcessDidTerminate(webView)
            XCTAssertEqual(webView.loadedHTML.count, 2)

            let error = WKError(.webContentProcessTerminated)
            if isProvisional {
                coordinator.webView(webView, didFailProvisionalNavigation: nil, withError: error)
            } else {
                coordinator.webView(webView, didFail: nil, withError: error)
            }
            coordinator.webView(webView, didFinish: nil)
            coordinator.loadContentIfReady(in: webView)

            XCTAssertEqual(webView.loadedHTML.count, 2, "isProvisional=\(isProvisional)")
            XCTAssertFalse(coordinator.needsReload, "isProvisional=\(isProvisional)")
        }
    }

    func testResetLoadedSignatureAfterFailureMakesCurrentContentEligibleForRetry() {
        let coordinator = BaseEmailWebView.Coordinator(makeWebView(message: nil))

        coordinator.recordLoadedSignature()
        XCTAssertFalse(coordinator.needsReload)

        coordinator.resetLoadedSignatureAfterFailure()

        XCTAssertTrue(coordinator.needsReload)
        XCTAssertEqual(coordinator.lastLoadedContent, "")
        XCTAssertEqual(coordinator.lastLoadedReloadSignature, "")
    }

    func testCancelledNavigationFailureBeforeFinishMakesCurrentContentEligibleForRetry() {
        let coordinator = BaseEmailWebView.Coordinator(makeWebView(message: nil))
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)

        coordinator.recordLoadedSignature()
        XCTAssertFalse(coordinator.needsReload)

        coordinator.resetLoadedSignatureAfterFailure(for: error)

        XCTAssertTrue(coordinator.needsReload)
    }

    func testCancelledNavigationFailureAfterFinishPreservesLoadedSignature() {
        let coordinator = BaseEmailWebView.Coordinator(makeWebView(message: nil))
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)

        coordinator.recordLoadedSignature()
        coordinator.recordFinishedLoad()
        XCTAssertFalse(coordinator.needsReload)

        coordinator.resetLoadedSignatureAfterFailure(for: error)

        XCTAssertFalse(coordinator.needsReload)
    }

    func testScaledPreviewLoadReadinessStillRequiresMeasuredHeight() {
        let coordinator = BaseEmailWebView.Coordinator(makeWebView(message: nil, mode: .scaledPreview(scale: 0.5)))

        let readiness = coordinator.loadReadiness(windowPresent: true, width: 320, height: 0.5)

        XCTAssertEqual(readiness, .deferred(reason: "missing-height"))
    }

    func testSimplePreviewLoadReadinessStillRequiresMeasuredHeight() {
        let coordinator = BaseEmailWebView.Coordinator(makeWebView(message: nil, mode: .simplePreview))

        let readiness = coordinator.loadReadiness(windowPresent: true, width: 320, height: 0.5)

        XCTAssertEqual(readiness, .deferred(reason: "missing-height"))
    }

    func testPreviewLoadReadinessRequiresWindowAndWidth() {
        let coordinator = BaseEmailWebView.Coordinator(makeWebView(message: nil, mode: .simplePreview))

        XCTAssertEqual(
            coordinator.loadReadiness(windowPresent: false, width: 320, height: 200),
            .deferred(reason: "missing-window")
        )
        XCTAssertEqual(
            coordinator.loadReadiness(windowPresent: true, width: 0.5, height: 200),
            .deferred(reason: "missing-width")
        )
    }

    func testModeDisplayPurposeUsesPreviewPolicy() {
        XCTAssertEqual(EmailWebViewMode.scaledPreview(scale: 0.5).displayPurpose, .preview)
        XCTAssertEqual(EmailWebViewMode.simplePreview.displayPurpose, .preview)
    }

    func testModeUserInterfaceStyleLeavesPreviewsUnspecified() {
        XCTAssertEqual(EmailWebViewMode.scaledPreview(scale: 0.5).webViewUserInterfaceStyle, .unspecified)
        XCTAssertEqual(EmailWebViewMode.simplePreview.webViewUserInterfaceStyle, .unspecified)
    }

    private func makeWebView(
        message: Message?,
        mode: EmailWebViewMode = .simplePreview,
        isDarkMode: Bool? = nil,
        html: String = "<html><body><img src=\"cid:image001@example.com\"></body></html>"
    ) -> BaseEmailWebView {
        BaseEmailWebView(
            htmlContent: html,
            mode: mode,
            isDarkMode: isDarkMode,
            message: message
        )
    }

    private func assertPendingReloadAfterFailure(isProvisional: Bool) {
        let coordinator = BaseEmailWebView.Coordinator(makeWebView(message: nil, html: "<p>Original</p>"))
        let webView = RecordingPreviewWebView()
        coordinator.loadContentIfReady(in: webView)
        coordinator.updateParent(makeWebView(message: nil, html: "<p>Latest</p>"))
        coordinator.loadContentIfReady(in: webView)
        XCTAssertEqual(webView.loadedHTML, ["<p>Original</p>"])

        failNavigation(coordinator, in: webView, isProvisional: isProvisional)

        XCTAssertEqual(webView.loadedHTML, ["<p>Original</p>", "<p>Latest</p>"])
        // The pending update is consumed once. A failure of that new document must not start a retry loop.
        failNavigation(coordinator, in: webView, isProvisional: isProvisional)
        XCTAssertEqual(webView.loadedHTML, ["<p>Original</p>", "<p>Latest</p>"])
        XCTAssertTrue(coordinator.needsReload)
    }

    private func failNavigation(
        _ coordinator: BaseEmailWebView.Coordinator,
        in webView: WKWebView,
        isProvisional: Bool
    ) {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        if isProvisional {
            coordinator.webView(webView, didFailProvisionalNavigation: nil, withError: error)
        } else {
            coordinator.webView(webView, didFail: nil, withError: error)
        }
    }

    private func makeMessage(id: String) -> Message {
        MessageBuilder()
            .withId(id)
            .build(in: coreDataStack.viewContext)
    }
}

@MainActor
private final class RecordingPreviewWebView: WKWebView {
    private let testWindow = UIWindow()
    private(set) var loadedHTML: [String] = []
    private(set) var loadedRequests: [URLRequest] = []

    // Supply a ready viewport without incidental UIKit layout callbacks replaying a missed update.
    override var window: UIWindow? { testWindow }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: WKWebViewConfiguration())
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
        loadedHTML.append(string)
        return nil
    }

    override func load(_ request: URLRequest) -> WKNavigation? {
        loadedRequests.append(request)
        return nil
    }
}
#endif
