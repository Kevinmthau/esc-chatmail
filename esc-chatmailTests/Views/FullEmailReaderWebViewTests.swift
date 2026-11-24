#if os(iOS)
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
            htmlContent: "<html><body>Hello</body></html>"
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

    // MARK: WebContent process termination

    // Revert-check: fails if `FullEmailReaderWebView.Coordinator.webViewWebContentProcessDidTerminate`
    // stops calling `discard` (the pool would re-host the dead view at dismantle: `reclaim` would
    // check it in), stops calling `onLoadFailed` (the placeholder stays gone over a blank view), or
    // stops reloading (the reader stays blank, because `needsReload` compares only the recorded
    // signature). Each was reverted on its own.
    func testWebContentTermination_adoptedReader_discardsPooledViewRestoresPlaceholderAndReloadsOwnContent() {
        let message = makeMessage(id: "terminated-adopted-reader", senderEmail: "news@sender.example")
        let adopter = RecordingTerminationAdopter()
        var loadFailedCount = 0
        let html = "<html><body><p>Adopted</p></body></html>"
        let coordinator = FullEmailReaderWebView.Coordinator(
            makeReader(
                message: message,
                htmlContent: html,
                webViewAdoptionProvider: adopter,
                onLoadFailed: { loadFailedCount += 1 }
            ),
            paintConfirmer: DeferredPaintConfirmer()
        )
        let webView = RecordingReaderWebView()
        coordinator.adoptAlreadyLoadedContent(html, messageId: message.id)
        XCTAssertFalse(coordinator.needsReload, "Precondition: the adopted content counts as loaded")

        coordinator.webViewWebContentProcessDidTerminate(webView)

        XCTAssertEqual(adopter.discards.map(\.messageId), [message.id])
        XCTAssertTrue(adopter.discards.first?.webView === webView)
        XCTAssertFalse(coordinator.hasAdoptedPrerenderedWebViewForTesting)
        XCTAssertEqual(loadFailedCount, 1)
        XCTAssertEqual(webView.loadedHTML, [html], "The reader reloads the content it holds")
        XCTAssertEqual(
            webView.loadedBaseURLs,
            [FullInteractiveEmailWebView.baseURL(message: message, senderEmail: nil)]
        )
        XCTAssertTrue(webView.loadedRequests.isEmpty, "Nothing is loaded by URL, the base URL included")
        XCTAssertFalse(coordinator.reclaimPrerenderedWebViewIfNeeded(webView))
        XCTAssertTrue(adopter.checkins.isEmpty, "A dead view is never checked back in")
    }

    // Revert-check: fails if the reader's handler resets the signature on every termination (drop
    // the `admitsReloadAfterWebContentTermination` guard, or its `wasDisplayed` condition): the
    // second termination of a reload that never painted then reloads, and so does every
    // `updateWebView` after it, which is a page that crashes WebKit reloading for as long as the
    // reader is open.
    func testWebContentTermination_beforeTheReloadPainted_doesNotReloadAgain() {
        var loadFailedCount = 0
        let coordinator = FullEmailReaderWebView.Coordinator(
            makeReader(message: nil, onLoadFailed: { loadFailedCount += 1 }),
            paintConfirmer: DeferredPaintConfirmer()
        )
        let webView = RecordingReaderWebView()
        coordinator.loadContentIfReady(in: webView)
        coordinator.webView(webView, didFinish: nil)
        XCTAssertEqual(webView.loadedHTML.count, 1)

        coordinator.webViewWebContentProcessDidTerminate(webView)
        XCTAssertEqual(webView.loadedHTML.count, 2)
        coordinator.webView(webView, didFinish: nil)

        coordinator.webViewWebContentProcessDidTerminate(webView)
        coordinator.loadContentIfReady(in: webView)

        XCTAssertEqual(webView.loadedHTML.count, 2)
        XCTAssertFalse(coordinator.needsReload)
        XCTAssertEqual(loadFailedCount, 2, "Each termination still restores the placeholder")

        coordinator.updateParent(makeReader(message: nil, htmlContent: "<p>Changed</p>"))
        coordinator.loadContentIfReady(in: webView)
        XCTAssertEqual(webView.loadedHTML.last, "<p>Changed</p>", "New content loads as before")
        coordinator.webViewWebContentProcessDidTerminate(webView)
        XCTAssertEqual(webView.loadedHTML.count, 4, "New content has a termination reload of its own")
    }

    // Revert-check: fails if `completePaintGate` stops calling
    // `recordDisplayedAfterWebContentTermination` (a second jetsam of a reader that recovered and
    // painted is not reloaded, and the reader stays dead until it is reopened), or if
    // `admitsReloadAfterWebContentTermination` loses its `maximumWebContentTerminationReloads`
    // bound (a page that paints and then crashes reloads without end).
    func testWebContentTermination_afterEachReloadPainted_reloadsAgainUpToTheCap() {
        let paintConfirmer = DeferredPaintConfirmer()
        let coordinator = FullEmailReaderWebView.Coordinator(
            makeReader(message: nil),
            paintConfirmer: paintConfirmer
        )
        let webView = RecordingReaderWebView()
        coordinator.loadContentIfReady(in: webView)
        coordinator.webView(webView, didFinish: nil)
        paintConfirmer.completeNext()

        for _ in 0..<EmailWebViewLoadCoordination.maximumWebContentTerminationReloads {
            coordinator.webViewWebContentProcessDidTerminate(webView)
            coordinator.webView(webView, didFinish: nil)
            paintConfirmer.completeNext()
        }
        XCTAssertEqual(
            webView.loadedHTML.count,
            1 + EmailWebViewLoadCoordination.maximumWebContentTerminationReloads,
            "Each termination after a painted reload reloads"
        )

        coordinator.webViewWebContentProcessDidTerminate(webView)
        coordinator.loadContentIfReady(in: webView)

        XCTAssertEqual(webView.loadedHTML.count, 1 + EmailWebViewLoadCoordination.maximumWebContentTerminationReloads)
        XCTAssertFalse(coordinator.needsReload)
    }

    // Revert-check: fails if `completeAdoptionCallbacksIfActive` loses its
    // `adoptedPrerenderedMessageId` guard: a termination in the turn between adoption and its
    // deferred callbacks restores the placeholder, and the callbacks then remove it again over the
    // blank view while the reload has not painted.
    func testWebContentTermination_beforeDeferredAdoptionCallbacks_keepsThePlaceholder() {
        var loadFinishedCount = 0
        var adoptedCount = 0
        var loadFailedCount = 0
        let html = "<html><body><p>Adopted</p></body></html>"
        let reader = FullEmailReaderWebView(
            htmlContent: html,
            sourceSignature: "sha256:source",
            message: nil,
            webViewAdoptionProvider: RecordingTerminationAdopter(),
            onLoadFinished: { loadFinishedCount += 1 },
            onLoadFailed: { loadFailedCount += 1 },
            onAdoptedPrerendered: { adoptedCount += 1 }
        )
        let coordinator = FullEmailReaderWebView.Coordinator(reader, paintConfirmer: DeferredPaintConfirmer())
        let webView = RecordingReaderWebView()
        coordinator.adoptAlreadyLoadedContent(html, messageId: "adopted-then-terminated")

        coordinator.webViewWebContentProcessDidTerminate(webView)
        coordinator.completeAdoptionCallbacksIfActive()

        XCTAssertEqual(loadFailedCount, 1)
        XCTAssertEqual(loadFinishedCount, 0)
        XCTAssertEqual(adoptedCount, 0)
    }

    // Revert-check: fails if the latched branch of the reader's termination handler stops calling
    // `resetPaintConfirmationState`: the confirmation started for the dead document then completes
    // and removes the placeholder over a blank view.
    func testWebContentTermination_latched_pendingPaintConfirmationCannotRemovePlaceholder() {
        let paintConfirmer = DeferredPaintConfirmer()
        var loadFinishedCount = 0
        let coordinator = FullEmailReaderWebView.Coordinator(
            makeReader(message: nil, onLoadFinished: { loadFinishedCount += 1 }),
            paintConfirmer: paintConfirmer
        )
        let webView = RecordingReaderWebView()
        coordinator.loadContentIfReady(in: webView)
        coordinator.webViewWebContentProcessDidTerminate(webView)
        coordinator.webView(webView, didFinish: nil)
        XCTAssertEqual(paintConfirmer.confirmPaintCallCount, 1)

        coordinator.webViewWebContentProcessDidTerminate(webView)
        paintConfirmer.completeNext()

        XCTAssertEqual(loadFinishedCount, 0)
    }

    // Revert-check: fails if `didFail` loses its `isWebContentProcessTerminationError` guard: the
    // failure resets the signature that the termination's reload recorded, and the next update
    // loads the same content again behind the latch's back.
    func testWebContentTermination_failureReportedForTheDeadNavigation_doesNotRearmAReload() {
        var loadFailedCount = 0
        let coordinator = FullEmailReaderWebView.Coordinator(
            makeReader(message: nil, onLoadFailed: { loadFailedCount += 1 }),
            paintConfirmer: DeferredPaintConfirmer()
        )
        let webView = RecordingReaderWebView()
        coordinator.loadContentIfReady(in: webView)
        coordinator.webViewWebContentProcessDidTerminate(webView)
        XCTAssertEqual(webView.loadedHTML.count, 2)

        coordinator.webView(webView, didFail: nil, withError: WKError(.webContentProcessTerminated))
        coordinator.webView(
            webView,
            didFailProvisionalNavigation: nil,
            withError: WKError(.webContentProcessTerminated)
        )
        coordinator.loadContentIfReady(in: webView)

        XCTAssertEqual(webView.loadedHTML.count, 2)
        XCTAssertFalse(coordinator.needsReload)
        XCTAssertEqual(loadFailedCount, 1)
    }

    // HONEST SCOPE: pins the outcome, not one guard. Removing the handler's own `isInvalidated`
    // guard does not fail this, because the scrub already replaced the parent with an empty reader
    // and `loadContentIfReady` refuses an invalidated coordinator. A scrubbed reader must load
    // nothing and call nothing back after a termination, whichever of them stops it.
    func testWebContentTermination_afterAccountScrub_reloadsNothing() {
        var loadFailedCount = 0
        let coordinator = FullEmailReaderWebView.Coordinator(
            makeReader(message: nil, onLoadFailed: { loadFailedCount += 1 })
        )
        let webView = RecordingReaderWebView()
        coordinator.loadContentIfReady(in: webView)
        coordinator.scrubForAccountBoundary(webView)
        let loadsAfterScrub = webView.loadedHTML

        coordinator.webViewWebContentProcessDidTerminate(webView)
        coordinator.loadContentIfReady(in: webView)

        XCTAssertEqual(webView.loadedHTML, loadsAfterScrub)
        XCTAssertEqual(loadFailedCount, 0)
    }

    // Revert-check: fails if `FullEmailReaderAccountBoundaryRegistry.register()`
    // loses its `acceptsAccountWork` admission guard — a reader whose makeUIView
    // runs during or after `clearForAccountTransition()` would keep old-account
    // DOM alive un-scrubbed.
    func testRegistryScrubsReadersRegisteredWhileAccountWorkIsClosingAndClosed() async {
        let blankDocumentAwaiter = DeferredFullEmailBlankDocumentAwaiter()
        let registry = FullEmailReaderAccountBoundaryRegistry { _ in
            await blankDocumentAwaiter.wait()
        }
        let clearTask = Task {
            await registry.clearForAccountTransition()
        }
        defer { blankDocumentAwaiter.resume() }

        await blankDocumentAwaiter.waitUntilStarted()
        XCTAssertTrue(blankDocumentAwaiter.isWaiting)

        let duringClear = makeAccountBoundaryRegistration(id: "registered-during-clear")
        registry.register(webView: duringClear.webView, coordinator: duringClear.coordinator)

        XCTAssertTrue(duringClear.coordinator.isInvalidatedForAccountTransitionForTesting)
        XCTAssertEqual(duringClear.coordinator.parent.htmlContent, "")
        XCTAssertNil(duringClear.coordinator.parent.message)
        XCTAssertNil(duringClear.coordinator.cidHandler)
        XCTAssertNil(duringClear.cidHandler.message)
        XCTAssertNil(duringClear.webView.navigationDelegate)
        XCTAssertNil(duringClear.webView.onLayoutChange)

        blankDocumentAwaiter.resume()
        await clearTask.value

        let whileClosed = makeAccountBoundaryRegistration(id: "registered-while-closed")
        registry.register(webView: whileClosed.webView, coordinator: whileClosed.coordinator)
        XCTAssertTrue(whileClosed.coordinator.isInvalidatedForAccountTransitionForTesting)

        registry.reopenAccountWork()
        let afterReopen = makeAccountBoundaryRegistration(id: "registered-after-reopen")
        registry.register(webView: afterReopen.webView, coordinator: afterReopen.coordinator)

        XCTAssertFalse(afterReopen.coordinator.isInvalidatedForAccountTransitionForTesting)
        XCTAssertTrue(afterReopen.webView.navigationDelegate === afterReopen.coordinator)
        XCTAssertNotNil(afterReopen.webView.onLayoutChange)

        registry.unregister(webView: afterReopen.webView)
        afterReopen.coordinator.scrubForAccountBoundary(afterReopen.webView)
    }

    // Revert-check: fails if `FullEmailWebViewManager.reopenAccountWork()` moves
    // the registry reopen back below its `activeWarmOperations` guard — a leaked
    // warm operation would then keep the process-wide registry closed, scrubbing
    // every future reader blank instead of merely leaving the prerender pool cold.
    // HONEST SCOPE: activeWarmOperations cannot be non-empty at reopen through
    // the public API today (warm() defers finishWarmOperation and close drains
    // the set before returning), so beginWarmOperationForTesting manufactures
    // the state; this pins defense-in-depth ordering against a future leak,
    // not a reachable production regression.
    func testManagerReopenReopensReaderRegistryEvenWhileWarmOperationsKeepPoolClosed() async {
        let manager = FullEmailWebViewManager()
        addTeardownBlock { @MainActor in
            FullEmailReaderAccountBoundaryRegistry.shared.reopenAccountWork()
        }
        await manager.clearForAccountTransition()

        let warmOperationID = manager.beginWarmOperationForTesting()
        manager.reopenAccountWork()
        XCTAssertFalse(
            manager.acceptsAccountWorkForTesting,
            "The pool must refuse to reopen while a warm operation is outstanding"
        )

        let reader = makeAccountBoundaryRegistration(id: "registered-after-refused-pool-reopen")
        FullEmailReaderAccountBoundaryRegistry.shared.register(
            webView: reader.webView,
            coordinator: reader.coordinator
        )
        XCTAssertFalse(reader.coordinator.isInvalidatedForAccountTransitionForTesting)
        XCTAssertTrue(reader.webView.navigationDelegate === reader.coordinator)
        FullEmailReaderAccountBoundaryRegistry.shared.unregister(webView: reader.webView)
        reader.coordinator.scrubForAccountBoundary(reader.webView)

        manager.finishWarmOperationForTesting(warmOperationID)
        manager.reopenAccountWork()
        XCTAssertTrue(manager.acceptsAccountWorkForTesting)
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
        // The shared registry is process-global: reopen it even if an assertion
        // failure or thrown error aborts this test between close and reopen.
        addTeardownBlock { @MainActor in
            FullEmailReaderAccountBoundaryRegistry.shared.reopenAccountWork()
        }
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

        let afterReopen = makeAccountBoundaryRegistration(id: "shared-registry-after-reopen")
        FullEmailReaderAccountBoundaryRegistry.shared.register(
            webView: afterReopen.webView,
            coordinator: afterReopen.coordinator
        )
        XCTAssertFalse(afterReopen.coordinator.isInvalidatedForAccountTransitionForTesting)
        FullEmailReaderAccountBoundaryRegistry.shared.unregister(webView: afterReopen.webView)
        afterReopen.coordinator.scrubForAccountBoundary(afterReopen.webView)
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
        webViewAdoptionProvider: (any FullEmailWebViewAdopting)? = nil,
        onLoadFinished: (() -> Void)? = nil,
        onLoadFailed: (() -> Void)? = nil
    ) -> FullEmailReaderWebView {
        FullEmailReaderWebView(
            htmlContent: htmlContent ?? defaultReaderHTML,
            sourceSignature: sourceSignature,
            message: message,
            webViewAdoptionProvider: webViewAdoptionProvider,
            onLoadFinished: onLoadFinished,
            onLoadFailed: onLoadFailed
        )
    }

    private func makeAccountBoundaryRegistration(
        id: String
    ) -> (
        coordinator: FullEmailReaderWebView.Coordinator,
        cidHandler: CIDSchemeHandler,
        webView: LayoutAwareWKWebView
    ) {
        let message = makeMessage(id: id)
        let coordinator = FullEmailReaderWebView.Coordinator(makeReader(message: message))
        let cidHandler = CIDSchemeHandler(message: message)
        coordinator.cidHandler = cidHandler
        let webView = LayoutAwareWKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600),
            configuration: FullInteractiveEmailWebView.makeConfiguration(cidHandler: cidHandler)
        )
        webView.navigationDelegate = coordinator
        webView.onLayoutChange = { _ in }
        return (coordinator, cidHandler, webView)
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

    private func makeMessage(id: String, senderEmail: String? = nil) -> Message {
        var builder = MessageBuilder().withId(id)
        if let senderEmail {
            builder = builder.withSender(email: senderEmail, name: "Sender")
        }
        return builder.build(in: coreDataStack.viewContext)
    }
}

/// Records the reader's loads and supplies a window and a size, so `loadContentIfReady` is ready
/// without layout callbacks. Nothing is really loaded.
@MainActor
private final class RecordingReaderWebView: WKWebView {
    private let testWindow = UIWindow()
    private(set) var loadedHTML: [String] = []
    private(set) var loadedBaseURLs: [URL?] = []
    private(set) var loadedRequests: [URLRequest] = []

    override var window: UIWindow? { testWindow }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: WKWebViewConfiguration())
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
        loadedHTML.append(string)
        loadedBaseURLs.append(baseURL)
        return nil
    }

    override func load(_ request: URLRequest) -> WKNavigation? {
        loadedRequests.append(request)
        return nil
    }
}

@MainActor
private final class RecordingTerminationAdopter: FullEmailWebViewAdopting {
    struct Record {
        let messageId: String
        let webView: WKWebView
    }

    private(set) var discards: [Record] = []
    private(set) var checkins: [Record] = []

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
        checkins.append(Record(messageId: messageId, webView: webView))
        return true
    }

    func discard(messageId: String, webView: WKWebView) {
        discards.append(Record(messageId: messageId, webView: webView))
    }
}

@MainActor
private final class DeferredFullEmailBlankDocumentAwaiter {
    private(set) var isWaiting = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        isWaiting = true
        startContinuation?.resume()
        startContinuation = nil
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !isWaiting else { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
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
#endif
