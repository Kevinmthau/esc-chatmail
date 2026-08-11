import XCTest
@testable import esc_chatmail

@MainActor
final class QuickLookViewTests: XCTestCase {
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

    func testPreviewIndexIsClampedToSnapshotBounds() {
        XCTAssertEqual(QuickLookView.clampedPreviewIndex(-1, itemCount: 2), 0)
        XCTAssertEqual(QuickLookView.clampedPreviewIndex(0, itemCount: 2), 0)
        XCTAssertEqual(QuickLookView.clampedPreviewIndex(1, itemCount: 2), 1)
        XCTAssertEqual(QuickLookView.clampedPreviewIndex(2, itemCount: 2), 1)
        XCTAssertEqual(QuickLookView.clampedPreviewIndex(.max, itemCount: 2), 1)
        XCTAssertEqual(QuickLookView.clampedPreviewIndex(1, itemCount: 0), 0)
    }
}
