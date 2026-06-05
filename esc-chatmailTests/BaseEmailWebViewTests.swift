import XCTest
import UIKit
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
        isDarkMode: Bool? = nil
    ) -> BaseEmailWebView {
        BaseEmailWebView(
            htmlContent: "<html><body><img src=\"cid:image001@example.com\"></body></html>",
            mode: mode,
            isDarkMode: isDarkMode,
            message: message
        )
    }

    private func makeMessage(id: String) -> Message {
        MessageBuilder()
            .withId(id)
            .build(in: coreDataStack.viewContext)
    }
}
