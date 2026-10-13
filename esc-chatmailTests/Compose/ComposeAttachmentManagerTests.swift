import CoreData
import XCTest
@testable import esc_chatmail

@MainActor
final class ComposeAttachmentManagerTests: XCTestCase {
    func testRecoveryCopiesRegularAndInlineFilesAndDiscardPreservesFailedMessage() throws {
        let stack = TestCoreDataStack()
        let context = stack.viewContext
        let source = MessageBuilder().withId("failed-forward-\(UUID().uuidString)").build(in: context)
        AttachmentPaths.setupDirectories()
        let regularPath = AttachmentPaths.originalPath(idOrUUID: "local_\(UUID().uuidString)", ext: "pdf")
        let inlinePath = AttachmentPaths.originalPath(idOrUUID: "local_\(UUID().uuidString)", ext: "png")
        let regularData = Data("original PDF".utf8)
        let inlineData = Data([0x89, 0x50, 0x4E, 0x47])
        XCTAssertTrue(AttachmentPaths.saveData(regularData, to: regularPath))
        XCTAssertTrue(AttachmentPaths.saveData(inlineData, to: inlinePath))
        defer {
            AttachmentPaths.deleteFile(at: regularPath)
            AttachmentPaths.deleteFile(at: inlinePath)
        }
        let regular = AttachmentBuilder()
            .withId("local_\(UUID().uuidString)")
            .withFilename("report.pdf")
            .withMimeType("application/pdf")
            .withLocalURL(regularPath)
            .forMessage(source)
            .build(in: context)
        let inline = AttachmentBuilder()
            .withId("local_\(UUID().uuidString)")
            .withFilename("logo.png")
            .withMimeType("image/png")
            .withContentId("logo@example.com")
            .withLocalURL(inlinePath)
            .forMessage(source)
            .build(in: context)
        try stack.saveViewContext()
        let leases = ComposeAttachmentLeaseRegistry()
        let manager = ComposeAttachmentManager(viewContext: context, leaseRegistry: leases)
        defer { manager.clear() }

        try manager.copyRecoveredAttachments([regular, inline].map { LocalAttachmentReference(objectID: $0.objectID) })

        let copiedRegular = try XCTUnwrap(manager.attachments.first)
        let copiedInline = try XCTUnwrap(manager.inlineAttachments.first)
        let copiedRegularPath = try XCTUnwrap(copiedRegular.localURL)
        let copiedInlinePath = try XCTUnwrap(copiedInline.localURL)
        XCTAssertNotEqual(copiedRegularPath, regularPath)
        XCTAssertNotEqual(copiedInlinePath, inlinePath)
        XCTAssertEqual(copiedInline.contentId, "logo@example.com")
        XCTAssertEqual(AttachmentPaths.loadData(from: copiedRegularPath), regularData)
        XCTAssertEqual(AttachmentPaths.loadData(from: copiedInlinePath), inlineData)
        XCTAssertEqual(leases.withProtectedResources { $0.attachmentIDs.count }, 2)

        manager.clear()

        XCTAssertFalse(source.isDeleted)
        XCTAssertTrue(regular.message === source)
        XCTAssertTrue(inline.message === source)
        XCTAssertEqual(AttachmentPaths.loadData(from: regularPath), regularData)
        XCTAssertEqual(AttachmentPaths.loadData(from: inlinePath), inlineData)
        XCTAssertNil(AttachmentPaths.loadData(from: copiedRegularPath))
        XCTAssertNil(AttachmentPaths.loadData(from: copiedInlinePath))
        XCTAssertTrue(leases.withProtectedResources { $0.attachmentIDs.isEmpty && $0.filePaths.isEmpty })
    }

    func testFailedInlineCopyCanBeDiscardedWithoutLeakingEarlierCopies() throws {
        let stack = TestCoreDataStack()
        let leases = ComposeAttachmentLeaseRegistry()
        let manager = ComposeAttachmentManager(viewContext: stack.viewContext, leaseRegistry: leases)
        AttachmentPaths.setupDirectories()
        let sourcePath = AttachmentPaths.originalPath(idOrUUID: "local_\(UUID().uuidString)", ext: "png")
        XCTAssertTrue(AttachmentPaths.saveData(Data([1, 2, 3]), to: sourcePath))
        defer { AttachmentPaths.deleteFile(at: sourcePath) }

        XCTAssertThrowsError(try manager.copyInlineAttachmentsForForward([
            .init(localURL: sourcePath, filename: "first.png", mimeType: "image/png", contentId: "first@example.com"),
            .init(localURL: "Attachments/\(UUID().uuidString).png", filename: "missing.png", mimeType: "image/png", contentId: "missing@example.com")
        ]))
        let copiedPath = try XCTUnwrap(manager.inlineAttachments.first?.localURL)

        manager.clear()

        XCTAssertNil(AttachmentPaths.loadData(from: copiedPath))
        XCTAssertNotNil(AttachmentPaths.loadData(from: sourcePath))
        XCTAssertTrue(leases.withProtectedResources { $0.attachmentIDs.isEmpty })
    }

    func testDiscardAfterSendFailurePreservesAttachmentsOwnedByRetainedMessage() throws {
        let stack = TestCoreDataStack()
        let leases = ComposeAttachmentLeaseRegistry()
        let manager = ComposeAttachmentManager(viewContext: stack.viewContext, leaseRegistry: leases)
        AttachmentPaths.setupDirectories()
        let sourcePath = AttachmentPaths.originalPath(idOrUUID: "local_\(UUID().uuidString)", ext: "png")
        let imageData = Data([1, 2, 3])
        XCTAssertTrue(AttachmentPaths.saveData(imageData, to: sourcePath))
        defer { AttachmentPaths.deleteFile(at: sourcePath) }
        try manager.copyInlineAttachmentsForForward([
            .init(localURL: sourcePath, filename: "logo.png", mimeType: "image/png", contentId: "logo@example.com")
        ])
        let attachment = try XCTUnwrap(manager.inlineAttachments.first)
        let copiedPath = try XCTUnwrap(attachment.localURL)
        defer { AttachmentPaths.deleteFile(at: copiedPath) }
        let retainedMessage = MessageBuilder().withId("retained-forward-\(UUID().uuidString)").build(in: stack.viewContext)
        attachment.message = retainedMessage
        try stack.saveViewContext()

        manager.clear()

        XCTAssertFalse(attachment.isDeleted)
        XCTAssertTrue(attachment.message === retainedMessage)
        XCTAssertEqual(AttachmentPaths.loadData(from: copiedPath), imageData)
        XCTAssertTrue(leases.withProtectedResources { $0.attachmentIDs.isEmpty })
    }
}
