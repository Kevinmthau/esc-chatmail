import XCTest
import UIKit
import WebKit
@testable import esc_chatmail

@MainActor
final class FullEmailReaderWebViewTests: XCTestCase {
    private var coreDataStack: TestCoreDataStack!

    override func setUp() {
        super.setUp()
        coreDataStack = TestCoreDataStack()
    }

    override func tearDown() {
        coreDataStack = nil
        super.tearDown()
    }

    func testHTMLWebViewBodyUsesFullEmailReaderWebView() {
        let body = HTMLWebView(
            htmlContent: "<html><body>Hello</body></html>",
            isDarkMode: true
        ).body

        XCTAssertEqual(String(describing: type(of: body)), "FullEmailReaderWebView")
    }

    func testFullInteractiveConfigurationDisablesUnneededCapabilitiesAndKeepsCIDHandler() {
        let cidHandler = CIDSchemeHandler(message: nil)
        let configuration = FullInteractiveEmailWebView.makeConfiguration(cidHandler: cidHandler)

        XCTAssertFalse(configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(configuration.allowsInlineMediaPlayback)
        XCTAssertFalse(configuration.allowsAirPlayForMediaPlayback)
        XCTAssertEqual(configuration.mediaTypesRequiringUserActionForPlayback, .all)
        XCTAssertTrue(configuration.urlSchemeHandler(forURLScheme: "cid") === cidHandler)
    }

    func testUpdateParentRefreshesCIDHandlerMessage() {
        let originalMessage = makeMessage(id: "message-a")
        let updatedMessage = makeMessage(id: "message-b")
        let originalView = makeReader(message: originalMessage)
        let updatedView = makeReader(message: updatedMessage)
        let coordinator = FullEmailReaderWebView.Coordinator(originalView)
        let cidHandler = CIDSchemeHandler(message: originalMessage)
        coordinator.cidHandler = cidHandler

        coordinator.updateParent(updatedView)

        XCTAssertTrue(coordinator.parent.message === updatedMessage)
        XCTAssertTrue(cidHandler.message === updatedMessage)
    }

    func testCoordinatorNeedsReloadWhenMessageIdentityChangesForSameHTML() {
        let originalMessage = makeMessage(id: "message-a")
        let updatedMessage = makeMessage(id: "message-b")
        let originalView = makeReader(message: originalMessage)
        let updatedView = makeReader(message: updatedMessage)
        let coordinator = FullEmailReaderWebView.Coordinator(originalView)

        coordinator.recordLoadedSignature()
        XCTAssertFalse(coordinator.needsReload)

        coordinator.updateParent(updatedView)

        XCTAssertTrue(coordinator.needsReload)
    }

    func testCoordinatorNeedsReloadWhenSourceSignatureChangesForSameHTML() {
        let message = makeMessage(id: "message-source-change")
        let originalView = makeReader(message: message, sourceSignature: "sha256:first")
        let updatedView = makeReader(message: message, sourceSignature: "sha256:second")
        let coordinator = FullEmailReaderWebView.Coordinator(originalView)

        coordinator.recordLoadedSignature()
        XCTAssertFalse(coordinator.needsReload)

        coordinator.updateParent(updatedView)

        XCTAssertTrue(coordinator.needsReload)
    }

    func testCoordinatorDoesNotReloadFullOriginalEmailForUnchangedSource() {
        let message = makeMessage(id: "message-unchanged")
        let originalView = makeReader(message: message, sourceSignature: "sha256:same")
        let updatedView = makeReader(message: message, sourceSignature: "sha256:same")
        let coordinator = FullEmailReaderWebView.Coordinator(originalView)

        coordinator.recordLoadedSignature()
        XCTAssertFalse(coordinator.needsReload)

        coordinator.updateParent(updatedView)

        XCTAssertFalse(coordinator.needsReload)
    }

    func testCoordinatorNeedsReloadWhenReferencedCIDAttachmentBecomesLocallyAvailable() throws {
        AttachmentPaths.setupDirectories()
        let message = makeMessage(id: "message-cid-reload")
        let attachment = AttachmentBuilder()
            .withId("att-cid-reload")
            .withFilename("image001.png")
            .withMimeType("image/png")
            .withContentId("image001@example.com")
            .queued()
            .forMessage(message)
            .build(in: coreDataStack.viewContext)
        try coreDataStack.saveViewContext()

        let coordinator = FullEmailReaderWebView.Coordinator(makeReader(message: message))
        coordinator.recordLoadedSignature()
        XCTAssertFalse(coordinator.needsReload)

        let localPath = AttachmentPaths.originalPath(idOrUUID: "att-cid-reload-\(UUID().uuidString)", ext: "png")
        XCTAssertTrue(AttachmentPaths.saveData(Data([0x89, 0x50, 0x4E, 0x47]), to: localPath))
        defer { AttachmentPaths.deleteFile(at: localPath) }

        attachment.localURL = localPath
        attachment.state = .downloaded
        try coreDataStack.saveViewContext()

        XCTAssertTrue(coordinator.needsReload)
    }

    func testCoordinatorDoesNotReloadWhenUnreferencedAttachmentBecomesLocallyAvailable() throws {
        AttachmentPaths.setupDirectories()
        let message = makeMessage(id: "message-unreferenced-cid")
        let attachment = AttachmentBuilder()
            .withId("att-unreferenced-cid")
            .withFilename("other.png")
            .withMimeType("image/png")
            .withContentId("other@example.com")
            .queued()
            .forMessage(message)
            .build(in: coreDataStack.viewContext)
        try coreDataStack.saveViewContext()

        let coordinator = FullEmailReaderWebView.Coordinator(makeReader(message: message))
        coordinator.recordLoadedSignature()
        XCTAssertFalse(coordinator.needsReload)

        let localPath = AttachmentPaths.originalPath(idOrUUID: "att-unreferenced-cid-\(UUID().uuidString)", ext: "png")
        XCTAssertTrue(AttachmentPaths.saveData(Data([0x89, 0x50, 0x4E, 0x47]), to: localPath))
        defer { AttachmentPaths.deleteFile(at: localPath) }

        attachment.localURL = localPath
        attachment.state = .downloaded
        try coreDataStack.saveViewContext()

        XCTAssertFalse(coordinator.needsReload)
    }

    func testCoordinatorDoesNotReloadForUnrelatedMessageAttachmentAvailabilityChange() throws {
        AttachmentPaths.setupDirectories()
        let currentMessage = makeMessage(id: "message-current-cid")
        let unrelatedMessage = makeMessage(id: "message-unrelated-cid")
        let unrelatedAttachment = AttachmentBuilder()
            .withId("att-unrelated-cid")
            .withFilename("image001.png")
            .withMimeType("image/png")
            .withContentId("image001@example.com")
            .queued()
            .forMessage(unrelatedMessage)
            .build(in: coreDataStack.viewContext)
        try coreDataStack.saveViewContext()

        let coordinator = FullEmailReaderWebView.Coordinator(makeReader(message: currentMessage))
        coordinator.recordLoadedSignature()
        XCTAssertFalse(coordinator.needsReload)

        let localPath = AttachmentPaths.originalPath(idOrUUID: "att-unrelated-cid-\(UUID().uuidString)", ext: "png")
        XCTAssertTrue(AttachmentPaths.saveData(Data([0x89, 0x50, 0x4E, 0x47]), to: localPath))
        defer { AttachmentPaths.deleteFile(at: localPath) }

        unrelatedAttachment.localURL = localPath
        unrelatedAttachment.state = .downloaded
        try coreDataStack.saveViewContext()

        XCTAssertFalse(coordinator.needsReload)
    }

    func testResetLoadedSignatureAfterFailureMakesCurrentContentEligibleForRetry() {
        let coordinator = FullEmailReaderWebView.Coordinator(makeReader(message: nil))

        coordinator.recordLoadedSignature()
        XCTAssertFalse(coordinator.needsReload)

        coordinator.resetLoadedSignatureAfterFailure()

        XCTAssertTrue(coordinator.needsReload)
        XCTAssertEqual(coordinator.lastLoadedContent, "")
        XCTAssertEqual(coordinator.lastLoadedReloadSignature, "")
    }

    func testCancelledNavigationFailureBeforeFinishMakesCurrentContentEligibleForRetry() {
        let coordinator = FullEmailReaderWebView.Coordinator(makeReader(message: nil))
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)

        coordinator.recordLoadedSignature()
        XCTAssertFalse(coordinator.needsReload)

        coordinator.resetLoadedSignatureAfterFailure(for: error)

        XCTAssertTrue(coordinator.needsReload)
    }

    func testCancelledNavigationFailureAfterFinishPreservesLoadedSignature() {
        let coordinator = FullEmailReaderWebView.Coordinator(makeReader(message: nil))
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)

        coordinator.recordLoadedSignature()
        coordinator.recordFinishedLoad()
        XCTAssertFalse(coordinator.needsReload)

        coordinator.resetLoadedSignatureAfterFailure(for: error)

        XCTAssertFalse(coordinator.needsReload)
    }

    func testFullReaderLoadReadinessDoesNotRequirePreviewHeight() {
        let coordinator = FullEmailReaderWebView.Coordinator(makeReader(message: nil))

        let readiness = coordinator.loadReadiness(windowPresent: true, width: 320, height: 0.5)

        XCTAssertEqual(readiness, .ready)
    }

    func testFullReaderLoadReadinessRequiresWindowAndWidth() {
        let coordinator = FullEmailReaderWebView.Coordinator(makeReader(message: nil))

        XCTAssertEqual(
            coordinator.loadReadiness(windowPresent: false, width: 320, height: 0.5),
            .deferred(reason: "missing-window")
        )
        XCTAssertEqual(
            coordinator.loadReadiness(windowPresent: true, width: 0.5, height: 0.5),
            .deferred(reason: "missing-width")
        )
    }

    func testLiveLoadCommitDoesNotStartPaintConfirmationBeforeFinish() {
        let paintConfirmer = DeferredPaintConfirmer()
        var loadFinishedCount = 0
        let coordinator = FullEmailReaderWebView.Coordinator(
            makeReader(message: nil, onLoadFinished: {
                loadFinishedCount += 1
            }),
            paintConfirmer: paintConfirmer
        )
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))

        coordinator.recordLoadedSignature()
        coordinator.webView(webView, didCommit: nil)

        XCTAssertEqual(loadFinishedCount, 0)
        XCTAssertEqual(paintConfirmer.confirmPaintCallCount, 0)

        coordinator.webView(webView, didFinish: nil)

        XCTAssertEqual(loadFinishedCount, 0)
        XCTAssertEqual(paintConfirmer.confirmPaintCallCount, 1)

        paintConfirmer.completeNext()

        XCTAssertEqual(loadFinishedCount, 1)
    }

    func testLiveLoadFinishStartsPaintConfirmation() {
        let paintConfirmer = DeferredPaintConfirmer()
        var loadFinishedCount = 0
        let coordinator = FullEmailReaderWebView.Coordinator(
            makeReader(message: nil, onLoadFinished: {
                loadFinishedCount += 1
            }),
            paintConfirmer: paintConfirmer
        )
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))

        coordinator.recordLoadedSignature()
        coordinator.webView(webView, didFinish: nil)

        XCTAssertEqual(loadFinishedCount, 0)
        XCTAssertEqual(paintConfirmer.confirmPaintCallCount, 1)

        paintConfirmer.completeNext()

        XCTAssertEqual(loadFinishedCount, 1)
    }

    func testFailedFinishPaintConfirmationRetriesOnce() {
        let paintConfirmer = DeferredPaintConfirmer()
        var loadFinishedCount = 0
        let coordinator = FullEmailReaderWebView.Coordinator(
            makeReader(message: nil, onLoadFinished: {
                loadFinishedCount += 1
            }),
            paintConfirmer: paintConfirmer
        )
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))

        coordinator.recordLoadedSignature()
        coordinator.webView(webView, didFinish: nil)

        XCTAssertEqual(paintConfirmer.confirmPaintCallCount, 1)
        paintConfirmer.completeNext(didPaint: false)

        XCTAssertEqual(loadFinishedCount, 0)
        XCTAssertEqual(paintConfirmer.confirmPaintCallCount, 2)
        paintConfirmer.completeNext()
        XCTAssertEqual(loadFinishedCount, 1)
    }

    func testTwoFailedPaintConfirmationsRevealOnlyAfterFinishFallback() {
        let paintConfirmer = DeferredPaintConfirmer()
        var loadFinishedCount = 0
        let coordinator = FullEmailReaderWebView.Coordinator(
            makeReader(message: nil, onLoadFinished: {
                loadFinishedCount += 1
            }),
            paintConfirmer: paintConfirmer
        )
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))

        coordinator.recordLoadedSignature()
        coordinator.webView(webView, didFinish: nil)
        paintConfirmer.completeNext(didPaint: false)

        XCTAssertEqual(loadFinishedCount, 0)
        XCTAssertEqual(paintConfirmer.confirmPaintCallCount, 2)

        paintConfirmer.completeNext(didPaint: false)

        XCTAssertEqual(loadFinishedCount, 1)
    }

    func testStalePaintConfirmationDoesNotFinishNewerLoad() {
        let paintConfirmer = DeferredPaintConfirmer()
        var loadFinishedCount = 0
        let coordinator = FullEmailReaderWebView.Coordinator(
            makeReader(message: nil, onLoadFinished: {
                loadFinishedCount += 1
            }),
            paintConfirmer: paintConfirmer
        )
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))

        coordinator.recordLoadedSignature()
        coordinator.webView(webView, didFinish: nil)
        coordinator.recordLoadedSignature()

        paintConfirmer.completeNext()

        XCTAssertEqual(loadFinishedCount, 0)
    }

    func testFailureResetInvalidatesPendingPaintConfirmation() {
        let paintConfirmer = DeferredPaintConfirmer()
        var loadFinishedCount = 0
        let coordinator = FullEmailReaderWebView.Coordinator(
            makeReader(message: nil, onLoadFinished: {
                loadFinishedCount += 1
            }),
            paintConfirmer: paintConfirmer
        )
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))

        coordinator.recordLoadedSignature()
        coordinator.webView(webView, didFinish: nil)
        coordinator.resetLoadedSignatureAfterFailure()

        paintConfirmer.completeNext()

        XCTAssertEqual(loadFinishedCount, 0)
        XCTAssertTrue(coordinator.needsReload)
    }

    func testFailureAfterConfirmedPaintRequestsPlaceholderRestore() {
        let paintConfirmer = DeferredPaintConfirmer()
        var loadFinishedCount = 0
        var loadFailedCount = 0
        let coordinator = FullEmailReaderWebView.Coordinator(
            makeReader(
                message: nil,
                onLoadFinished: { loadFinishedCount += 1 },
                onLoadFailed: { loadFailedCount += 1 }
            ),
            paintConfirmer: paintConfirmer
        )
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotDecodeContentData)

        coordinator.recordLoadedSignature()
        coordinator.webView(webView, didFinish: nil)
        paintConfirmer.completeNext()
        coordinator.webView(webView, didFail: nil, withError: error)

        XCTAssertEqual(loadFinishedCount, 1)
        XCTAssertEqual(loadFailedCount, 1)
        XCTAssertTrue(coordinator.needsReload)
    }

    func testCancelledFailureAfterFinishDoesNotRequestPlaceholderRestore() {
        let paintConfirmer = DeferredPaintConfirmer()
        var loadFailedCount = 0
        let coordinator = FullEmailReaderWebView.Coordinator(
            makeReader(message: nil, onLoadFailed: { loadFailedCount += 1 }),
            paintConfirmer: paintConfirmer
        )
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)

        coordinator.recordLoadedSignature()
        coordinator.webView(webView, didFinish: nil)
        paintConfirmer.completeNext()
        coordinator.webView(webView, didFail: nil, withError: error)

        XCTAssertEqual(loadFailedCount, 0)
        XCTAssertFalse(coordinator.needsReload)
    }

    func testAdoptedPrerenderedContentMarksLoadedWithoutLivePaintConfirmation() {
        let paintConfirmer = DeferredPaintConfirmer()
        let coordinator = FullEmailReaderWebView.Coordinator(
            makeReader(message: nil),
            paintConfirmer: paintConfirmer
        )

        coordinator.adoptAlreadyLoadedContent(
            defaultReaderHTML,
            messageId: "message-adopted"
        )

        XCTAssertFalse(coordinator.needsReload)
        XCTAssertTrue(coordinator.hasAdoptedPrerenderedWebViewForTesting)
        XCTAssertEqual(paintConfirmer.confirmPaintCallCount, 0)
    }

    func testAdoptedPrerenderedWebViewMarkerClearsOnReclaim() {
        let coordinator = FullEmailReaderWebView.Coordinator(makeReader(message: nil))
        let webView = WKWebView()

        coordinator.adoptAlreadyLoadedContent(
            "<html><body><p>ready</p></body></html>",
            messageId: "message-adopted"
        )
        XCTAssertTrue(coordinator.hasAdoptedPrerenderedWebViewForTesting)

        coordinator.reclaimPrerenderedWebViewIfNeeded(webView)

        XCTAssertFalse(coordinator.hasAdoptedPrerenderedWebViewForTesting)
    }

    func testAccountTransitionScrubsFreshReaderAndRejectsStalePaintCallback() async throws {
        let oldAccountMarker = "PRIVATE_FRESH_READER_\(UUID().uuidString)"
        let message = makeMessage(id: "fresh-reader")
        let paintConfirmer = DeferredPaintConfirmer()
        var loadFinishedCount = 0
        let reader = makeReader(
            message: message,
            htmlContent: "<html><body>\(oldAccountMarker)</body></html>",
            onLoadFinished: { loadFinishedCount += 1 }
        )
        let coordinator = FullEmailReaderWebView.Coordinator(
            reader,
            paintConfirmer: paintConfirmer
        )
        let cidHandler = CIDSchemeHandler(message: message)
        coordinator.cidHandler = cidHandler
        let webView = LayoutAwareWKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600),
            configuration: FullInteractiveEmailWebView.makeConfiguration(cidHandler: cidHandler)
        )
        webView.navigationDelegate = coordinator
        FullEmailReaderAccountBoundaryRegistry.shared.register(
            webView: webView,
            coordinator: coordinator
        )
        webView.loadHTMLString(reader.htmlContent, baseURL: URL(string: "about:blank"))
        try await waitForBody(in: webView) { $0.contains(oldAccountMarker) }

        for _ in 0..<100 where paintConfirmer.confirmPaintCallCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(paintConfirmer.confirmPaintCallCount, 1)

        let manager = FullEmailWebViewManager()
        await manager.clearForAccountTransition()
        manager.reopenAccountWork()
        coordinator.updateParent(reader)
        paintConfirmer.completeNext()

        let bodyText = try await webView.evaluateJavaScript("document.body.innerText") as? String

        XCTAssertTrue(coordinator.isInvalidatedForAccountTransitionForTesting)
        XCTAssertEqual(coordinator.parent.htmlContent, "")
        XCTAssertNil(coordinator.parent.message)
        XCTAssertNil(coordinator.cidHandler)
        XCTAssertNil(cidHandler.message)
        XCTAssertNil(webView.navigationDelegate)
        XCTAssertNil(webView.onLayoutChange)
        XCTAssertFalse(bodyText?.contains(oldAccountMarker) == true)
        XCTAssertEqual(loadFinishedCount, 0)
    }

    func testNormalDismantleScrubsFreshReader() {
        let message = makeMessage(id: "fresh-reader-dismantle")
        let reader = makeReader(message: message)
        let coordinator = FullEmailReaderWebView.Coordinator(reader)
        let cidHandler = CIDSchemeHandler(message: message)
        coordinator.cidHandler = cidHandler
        let webView = LayoutAwareWKWebView(
            frame: .zero,
            configuration: FullInteractiveEmailWebView.makeConfiguration(cidHandler: cidHandler)
        )
        webView.navigationDelegate = coordinator
        webView.onLayoutChange = { _ in }

        FullEmailReaderWebView.dismantleUIView(webView, coordinator: coordinator)

        XCTAssertTrue(coordinator.isInvalidatedForAccountTransitionForTesting)
        XCTAssertNil(coordinator.parent.message)
        XCTAssertNil(cidHandler.message)
        XCTAssertNil(webView.navigationDelegate)
        XCTAssertNil(webView.onLayoutChange)
    }

    private func makeReader(
        message: Message?,
        htmlContent: String? = nil,
        sourceSignature: String? = "sha256:source",
        onLoadFinished: (() -> Void)? = nil,
        onLoadFailed: (() -> Void)? = nil
    ) -> FullEmailReaderWebView {
        FullEmailReaderWebView(
            htmlContent: htmlContent ?? defaultReaderHTML,
            sourceSignature: sourceSignature,
            message: message,
            onLoadFinished: onLoadFinished,
            onLoadFailed: onLoadFailed
        )
    }

    private func waitForBody(
        in webView: WKWebView,
        satisfying predicate: (String) -> Bool
    ) async throws {
        for _ in 0..<100 {
            if let value = try? await webView.evaluateJavaScript("document.body.innerText"),
               let bodyText = value as? String,
               predicate(bodyText) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for the expected full-reader DOM")
    }

    private var defaultReaderHTML: String {
        "<html><body><img src=\"cid:image001@example.com\"></body></html>"
    }

    private func makeMessage(id: String) -> Message {
        MessageBuilder()
            .withId(id)
            .build(in: coreDataStack.viewContext)
    }
}

private final class DeferredPaintConfirmer: FullEmailReaderPaintConfirming {
    private var completions: [(Bool) -> Void] = []
    private(set) var confirmPaintCallCount = 0

    func confirmPaint(in webView: WKWebView, completion: @escaping (Bool) -> Void) {
        confirmPaintCallCount += 1
        completions.append(completion)
    }

    func completeNext(didPaint: Bool = true) {
        guard !completions.isEmpty else {
            XCTFail("Expected a pending paint confirmation")
            return
        }

        completions.removeFirst()(didPaint)
    }
}
