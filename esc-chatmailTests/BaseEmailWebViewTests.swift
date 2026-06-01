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

        let coordinator = BaseEmailWebView.Coordinator(makeWebView(message: message))
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

        let coordinator = BaseEmailWebView.Coordinator(makeWebView(message: message))
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

        let coordinator = BaseEmailWebView.Coordinator(makeWebView(message: currentMessage))
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

    func testModeDisplayPurposeUsesOriginalPolicyOnlyForFullInteractiveEmail() {
        XCTAssertEqual(EmailWebViewMode.fullInteractive.displayPurpose, .original)
        XCTAssertEqual(EmailWebViewMode.scaledPreview(scale: 0.5).displayPurpose, .preview)
        XCTAssertEqual(EmailWebViewMode.simplePreview.displayPurpose, .preview)
    }

    func testModeUserInterfaceStyleForcesLightOnlyForFullOriginalEmail() {
        XCTAssertEqual(EmailWebViewMode.fullInteractive.webViewUserInterfaceStyle, .light)
        XCTAssertEqual(EmailWebViewMode.scaledPreview(scale: 0.5).webViewUserInterfaceStyle, .unspecified)
        XCTAssertEqual(EmailWebViewMode.simplePreview.webViewUserInterfaceStyle, .unspecified)
    }

    private func makeWebView(message: Message?) -> BaseEmailWebView {
        BaseEmailWebView(
            htmlContent: "<html><body><img src=\"cid:image001@example.com\"></body></html>",
            mode: .fullInteractive,
            message: message
        )
    }

    private func makeMessage(id: String) -> Message {
        MessageBuilder()
            .withId(id)
            .build(in: coreDataStack.viewContext)
    }
}
