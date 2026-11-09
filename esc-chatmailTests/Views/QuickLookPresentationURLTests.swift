import XCTest
@testable import esc_chatmail

/// The Mac shows attachments with SwiftUI's URL-based `.quickLookPreview`
/// (`AttachmentQuickLookModifier`), fed by `QuickLookPresentation.itemURLs` and
/// `selectedItemURL`. Those must list the same snapshot iOS's `QuickLookPreviewController` pages
/// through and open on the tapped file. The helpers are platform-neutral, so they are pinned here
/// on iOS.
///
/// Fixtures go through a main-queue context from `TestCoreDataStack.makeMainQueueViewContext()`,
/// as in `QuickLookPreviewControllerTests`.
///
/// HONEST SCOPE: the Quick Look panel itself needs a Mac window; only the URLs it is given are
/// checked here.
@MainActor
final class QuickLookPresentationURLTests: XCTestCase {
    /// Revert-check: returning the first item's URL from `QuickLookPresentation.selectedItemURL`
    /// makes this fail.
    func testItemURLs_twoReadableAttachments_listBothInOrderAndSelectTappedOne() throws {
        let stack = TestCoreDataStack()
        let context = stack.makeMainQueueViewContext()
        let message = MessageBuilder()
            .withId("quick-look-url-message-\(UUID().uuidString)")
            .withAttachments()
            .build(in: context)

        let firstID = "quick-look-url-first"
        let firstPath = AttachmentPaths.originalPath(messageId: message.id, attachmentId: firstID, ext: "pdf")
        let first = AttachmentBuilder()
            .withId(firstID)
            .withFilename("first.pdf")
            .withMimeType("application/pdf")
            .withLocalURL(firstPath)
            .downloaded()
            .forMessage(message)
            .build(in: context)

        let secondID = "quick-look-url-second"
        let secondPath = AttachmentPaths.originalPath(messageId: message.id, attachmentId: secondID, ext: "pdf")
        let second = AttachmentBuilder()
            .withId(secondID)
            .withFilename("second.pdf")
            .withMimeType("application/pdf")
            .withLocalURL(secondPath)
            .downloaded()
            .forMessage(message)
            .build(in: context)

        AttachmentPaths.setupDirectories()
        XCTAssertTrue(AttachmentPaths.saveData(Data("first".utf8), to: firstPath))
        XCTAssertTrue(AttachmentPaths.saveData(Data("second".utf8), to: secondPath))
        defer {
            AttachmentPaths.deleteFile(at: firstPath)
            AttachmentPaths.deleteFile(at: secondPath)
        }

        let presentation = try XCTUnwrap(
            QuickLookPresentation(attachments: [first, second], selectedAttachment: second)
        )

        let firstURL = try XCTUnwrap(AttachmentPaths.fullURL(for: firstPath))
        let secondURL = try XCTUnwrap(AttachmentPaths.fullURL(for: secondPath))
        XCTAssertEqual(presentation.itemURLs, [firstURL, secondURL])
        XCTAssertEqual(presentation.selectedItemURL, secondURL)
    }
}
