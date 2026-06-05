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

    func testLiveLoadFinishedWaitsForPaintConfirmation() {
        let paintConfirmer = DeferredPaintConfirmer()
        var loadFinishedCount = 0
        let coordinator = FullEmailReaderWebView.Coordinator(
            makeReader(message: nil) {
                loadFinishedCount += 1
            },
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

    func testStalePaintConfirmationDoesNotFinishNewerLoad() {
        let paintConfirmer = DeferredPaintConfirmer()
        var loadFinishedCount = 0
        let coordinator = FullEmailReaderWebView.Coordinator(
            makeReader(message: nil) {
                loadFinishedCount += 1
            },
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
            makeReader(message: nil) {
                loadFinishedCount += 1
            },
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

    private func makeReader(
        message: Message?,
        sourceSignature: String? = "sha256:source",
        onLoadFinished: (() -> Void)? = nil
    ) -> FullEmailReaderWebView {
        FullEmailReaderWebView(
            htmlContent: defaultReaderHTML,
            sourceSignature: sourceSignature,
            message: message,
            onLoadFinished: onLoadFinished
        )
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
    private var completions: [() -> Void] = []
    private(set) var confirmPaintCallCount = 0

    func confirmPaint(in webView: WKWebView, completion: @escaping () -> Void) {
        confirmPaintCallCount += 1
        completions.append(completion)
    }

    func completeNext() {
        guard !completions.isEmpty else {
            XCTFail("Expected a pending paint confirmation")
            return
        }

        completions.removeFirst()()
    }
}
