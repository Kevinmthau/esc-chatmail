import XCTest
import UIKit
@testable import esc_chatmail

@MainActor
final class QuickLookPreviewControllerTests: XCTestCase {
    func testPresentationKeepsSelectionIndexAlignedAfterRejectingLegacyPath() throws {
        let stack = TestCoreDataStack()
        let context = stack.viewContext
        let message = MessageBuilder()
            .withId("quick-look-message")
            .withAttachments()
            .build(in: context)

        let legacyID = "quick-look-legacy"
        let legacyPath = AttachmentPaths.originalPath(idOrUUID: legacyID, ext: "pdf")
        let legacy = AttachmentBuilder()
            .withId(legacyID)
            .withFilename("legacy.pdf")
            .withMimeType("application/pdf")
            .withLocalURL(legacyPath)
            .downloaded()
            .forMessage(message)
            .build(in: context)

        let currentID = "quick-look-current"
        let currentPath = AttachmentPaths.originalPath(
            messageId: message.id,
            attachmentId: currentID,
            ext: "pdf"
        )
        let current = AttachmentBuilder()
            .withId(currentID)
            .withFilename("current.pdf")
            .withMimeType("application/pdf")
            .withLocalURL(currentPath)
            .downloaded()
            .forMessage(message)
            .build(in: context)

        AttachmentPaths.setupDirectories()
        XCTAssertTrue(AttachmentPaths.saveData(Data("legacy".utf8), to: legacyPath))
        XCTAssertTrue(AttachmentPaths.saveData(Data("current".utf8), to: currentPath))
        defer {
            AttachmentPaths.deleteFile(at: legacyPath)
            AttachmentPaths.deleteFile(at: currentPath)
        }

        let presentation = try XCTUnwrap(
            QuickLookPresentation(
                attachments: [legacy, current],
                selectedAttachment: current
            )
        )

        XCTAssertEqual(presentation.previewItems.map(\.attachment), [current])
        XCTAssertEqual(presentation.selectedIndex, 0)
    }

    func testPresentationKeepsSnapshotStableWhenFileDisappearsAfterCreation() throws {
        let stack = TestCoreDataStack()
        let context = stack.viewContext
        let message = MessageBuilder()
            .withId("quick-look-disappearing-message")
            .withAttachments()
            .build(in: context)

        let disappearingID = "quick-look-disappearing"
        let disappearingPath = AttachmentPaths.originalPath(
            messageId: message.id,
            attachmentId: disappearingID,
            ext: "pdf"
        )
        let disappearing = AttachmentBuilder()
            .withId(disappearingID)
            .withFilename("disappearing.pdf")
            .withMimeType("application/pdf")
            .withLocalURL(disappearingPath)
            .downloaded()
            .forMessage(message)
            .build(in: context)

        let selectedID = "quick-look-selected"
        let selectedPath = AttachmentPaths.originalPath(
            messageId: message.id,
            attachmentId: selectedID,
            ext: "pdf"
        )
        let selected = AttachmentBuilder()
            .withId(selectedID)
            .withFilename("selected.pdf")
            .withMimeType("application/pdf")
            .withLocalURL(selectedPath)
            .downloaded()
            .forMessage(message)
            .build(in: context)

        AttachmentPaths.setupDirectories()
        XCTAssertTrue(AttachmentPaths.saveData(Data("gone".utf8), to: disappearingPath))
        XCTAssertTrue(AttachmentPaths.saveData(Data("selected".utf8), to: selectedPath))
        defer {
            AttachmentPaths.deleteFile(at: disappearingPath)
            AttachmentPaths.deleteFile(at: selectedPath)
        }

        let presentation = try XCTUnwrap(
            QuickLookPresentation(
                attachments: [disappearing, selected],
                selectedAttachment: selected
            )
        )

        XCTAssertEqual(presentation.previewItems.map(\.attachment), [disappearing, selected])
        XCTAssertEqual(presentation.selectedIndex, 1)

        AttachmentPaths.deleteFile(at: disappearingPath)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: try XCTUnwrap(AttachmentPaths.fullURL(for: disappearingPath)).path
            )
        )
        XCTAssertEqual(presentation.previewItems.map(\.attachment), [disappearing, selected])
        XCTAssertEqual(presentation.selectedIndex, 1)
    }

    func testPresentationFailsWhenSelectedFileDisappearedBeforeSnapshot() {
        let stack = TestCoreDataStack()
        let context = stack.viewContext
        let message = MessageBuilder()
            .withId("quick-look-missing-selection-message")
            .withAttachments()
            .build(in: context)
        let selectedID = "quick-look-missing-selection"
        let selectedPath = AttachmentPaths.originalPath(
            messageId: message.id,
            attachmentId: selectedID,
            ext: "pdf"
        )
        let selected = AttachmentBuilder()
            .withId(selectedID)
            .withFilename("missing.pdf")
            .withMimeType("application/pdf")
            .withLocalURL(selectedPath)
            .downloaded()
            .forMessage(message)
            .build(in: context)

        AttachmentPaths.deleteFile(at: selectedPath)

        XCTAssertNil(
            QuickLookPresentation(
                attachments: [selected],
                selectedAttachment: selected
            )
        )
    }

    /// Revert-check: `QuickLookPreviewController.previewControllerDidDismiss` forwarding to
    /// `onDismiss` is what clears `AttachmentGridView`'s presentation state after a Done
    /// tap or pull-down, releasing the snapshot's `Attachment` objects. (A stale state
    /// would not block the next tap: each tap stores a presentation with a new id.)
    func testController_dismissedByQuickLook_invokesOnDismissAndServesSnapshot() throws {
        let stack = TestCoreDataStack()
        let context = stack.viewContext
        let message = MessageBuilder()
            .withId("quick-look-dismiss-message")
            .withAttachments()
            .build(in: context)
        let attachmentID = "quick-look-dismiss"
        let path = AttachmentPaths.originalPath(
            messageId: message.id,
            attachmentId: attachmentID,
            ext: "pdf"
        )
        let attachment = AttachmentBuilder()
            .withId(attachmentID)
            .withFilename("dismiss.pdf")
            .withMimeType("application/pdf")
            .withLocalURL(path)
            .downloaded()
            .forMessage(message)
            .build(in: context)

        AttachmentPaths.setupDirectories()
        XCTAssertTrue(AttachmentPaths.saveData(Data("dismiss".utf8), to: path))
        defer { AttachmentPaths.deleteFile(at: path) }

        let presentation = try XCTUnwrap(
            QuickLookPresentation(attachments: [attachment], selectedAttachment: attachment)
        )
        let controller = QuickLookPreviewController(presentation: presentation)
        var dismissCount = 0
        controller.onDismiss = { dismissCount += 1 }

        XCTAssertTrue(controller.dataSource === controller)
        XCTAssertTrue(controller.delegate === controller)
        XCTAssertEqual(controller.numberOfPreviewItems(in: controller), 1)
        let item = try XCTUnwrap(
            controller.previewController(controller, previewItemAt: 0) as? AttachmentPreviewItem
        )
        XCTAssertEqual(item.previewItemTitle, "dismiss.pdf")

        controller.previewControllerDidDismiss(controller)

        XCTAssertEqual(dismissCount, 1)
    }

    /// The mailbox closing (sign-out, revoked credentials) must take Quick Look down: it is a
    /// UIKit modal over the root hosting controller, so removing the mailbox view does not.
    ///
    /// Revert-check: removing `presentedControllers.add(controller)` from
    /// `QuickLookPreviewController.present`, or the dismissal loop in
    /// `QuickLookPreviewController.dismissAll`, makes this fail.
    /// HONEST SCOPE: `ContentView`'s `canAccessMailbox` hook that calls `dismissAll` is
    /// not exercised here.
    func testDismissAll_presentedQuickLook_isDismissed() async throws {
        let stack = TestCoreDataStack()
        let context = stack.viewContext
        let message = MessageBuilder()
            .withId("quick-look-dismiss-all-message")
            .withAttachments()
            .build(in: context)
        let attachmentID = "quick-look-dismiss-all"
        let path = AttachmentPaths.originalPath(
            messageId: message.id,
            attachmentId: attachmentID,
            ext: "pdf"
        )
        let attachment = AttachmentBuilder()
            .withId(attachmentID)
            .withFilename("dismiss-all.pdf")
            .withMimeType("application/pdf")
            .withLocalURL(path)
            .downloaded()
            .forMessage(message)
            .build(in: context)

        AttachmentPaths.setupDirectories()
        XCTAssertTrue(AttachmentPaths.saveData(Data("dismiss-all".utf8), to: path))
        defer { AttachmentPaths.deleteFile(at: path) }

        let presentation = try XCTUnwrap(
            QuickLookPresentation(attachments: [attachment], selectedAttachment: attachment)
        )
        let rootViewController = UIViewController()
        let window = try makeTestHostWindow()
        window.rootViewController = rootViewController
        window.isHidden = false
        addTeardownBlock { @MainActor in
            window.isHidden = true
        }

        let presented = await QuickLookPreviewController.present(presentation, onDismiss: {}) { controller in
            rootViewController.present(controller, animated: false)
            return true
        }
        XCTAssertTrue(presented)
        await waitUntil { rootViewController.presentedViewController is QuickLookPreviewController }

        QuickLookPreviewController.dismissAll()

        await waitUntil { rootViewController.presentedViewController == nil }
    }

    func testPreviewIndexIsClampedToSnapshotBounds() {
        XCTAssertEqual(QuickLookPreviewController.clampedPreviewIndex(-1, itemCount: 2), 0)
        XCTAssertEqual(QuickLookPreviewController.clampedPreviewIndex(0, itemCount: 2), 0)
        XCTAssertEqual(QuickLookPreviewController.clampedPreviewIndex(1, itemCount: 2), 1)
        XCTAssertEqual(QuickLookPreviewController.clampedPreviewIndex(2, itemCount: 2), 1)
        XCTAssertEqual(QuickLookPreviewController.clampedPreviewIndex(.max, itemCount: 2), 1)
        XCTAssertEqual(QuickLookPreviewController.clampedPreviewIndex(1, itemCount: 0), 0)
    }

    private func waitUntil(
        timeout: TimeInterval = 5.0,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}
