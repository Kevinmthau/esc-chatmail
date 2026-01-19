import XCTest
import CoreData
@testable import esc_chatmail

/// Tests for AttachmentDownloader infrastructure and state management.
///
/// Note: Full integration tests with actual download behavior require network mocking.
/// These tests focus on:
/// - Attachment state transitions
/// - Core Data entity handling
/// - Cleanup logic validation
final class AttachmentDownloaderTests: XCTestCase {

    var testStack: TestCoreDataStack!
    var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        context = testStack.viewContext
    }

    override func tearDown() {
        context = nil
        testStack = nil
        super.tearDown()
    }

    // MARK: - AttachmentBuilder Tests

    func testAttachmentBuilder_createsBasicAttachment() throws {
        let attachment = AttachmentBuilder()
            .withId("att-123")
            .withFilename("test.txt")
            .withMimeType("text/plain")
            .queued()
            .build(in: context)

        XCTAssertEqual(attachment.id, "att-123")
        XCTAssertEqual(attachment.filename, "test.txt")
        XCTAssertEqual(attachment.mimeType, "text/plain")
        XCTAssertEqual(attachment.state, .queued)
    }

    func testAttachmentBuilder_createsImageAttachment() throws {
        let attachment = AttachmentBuilder()
            .asImage(width: 1920, height: 1080)
            .downloaded()
            .withLocalURL("Attachments/photo.jpg")
            .withPreviewURL("Previews/photo.jpg")
            .build(in: context)

        XCTAssertEqual(attachment.mimeType, "image/jpeg")
        XCTAssertEqual(attachment.width, 1920)
        XCTAssertEqual(attachment.height, 1080)
        XCTAssertEqual(attachment.state, .downloaded)
        XCTAssertEqual(attachment.localURL, "Attachments/photo.jpg")
        XCTAssertEqual(attachment.previewURL, "Previews/photo.jpg")
    }

    func testAttachmentBuilder_createsPDFAttachment() throws {
        let attachment = AttachmentBuilder()
            .asPDF(pageCount: 5)
            .downloaded()
            .build(in: context)

        XCTAssertEqual(attachment.mimeType, "application/pdf")
        XCTAssertEqual(attachment.pageCount, 5)
        XCTAssertEqual(attachment.state, .downloaded)
    }

    func testAttachmentBuilder_linksToMessage() throws {
        let message = MessageBuilder()
            .withId("msg-123")
            .withSubject("Test with attachment")
            .build(in: context)

        let attachment = AttachmentBuilder()
            .withId("att-456")
            .forMessage(message)
            .build(in: context)

        XCTAssertEqual(attachment.message?.id, "msg-123")
    }

    // MARK: - State Transition Tests

    func testAttachmentState_transitionsFromQueuedToDownloaded() throws {
        let attachment = AttachmentBuilder()
            .queued()
            .build(in: context)

        XCTAssertEqual(attachment.state, .queued)

        attachment.state = .downloaded
        XCTAssertEqual(attachment.state, .downloaded)

        try testStack.saveViewContext()

        // Verify persistence
        let fetchedAttachment = try context.existingObject(with: attachment.objectID) as? Attachment
        XCTAssertEqual(fetchedAttachment?.state, .downloaded)
    }

    func testAttachmentState_transitionsFromQueuedToFailed() throws {
        let attachment = AttachmentBuilder()
            .queued()
            .build(in: context)

        XCTAssertEqual(attachment.state, .queued)

        attachment.state = .failed
        XCTAssertEqual(attachment.state, .failed)

        try testStack.saveViewContext()

        let fetchedAttachment = try context.existingObject(with: attachment.objectID) as? Attachment
        XCTAssertEqual(fetchedAttachment?.state, .failed)
    }

    func testAttachmentState_transitionsFromFailedToQueued() throws {
        // Simulates retry scenario
        let attachment = AttachmentBuilder()
            .failed()
            .build(in: context)

        XCTAssertEqual(attachment.state, .failed)

        // Reset for retry
        attachment.state = .queued
        XCTAssertEqual(attachment.state, .queued)
    }

    // MARK: - Query Tests

    func testFetchAttachments_filtersByState() throws {
        // Create attachments with different states
        let _ = AttachmentBuilder()
            .withId("att-queued")
            .queued()
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-downloaded")
            .downloaded()
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-failed")
            .failed()
            .build(in: context)

        try testStack.saveViewContext()

        // Fetch queued only (like AttachmentDownloader.enqueueAllPendingAttachments)
        let request = Attachment.fetchRequest()
        request.predicate = NSPredicate(format: "stateRaw == %@", "queued")

        let results = try context.fetch(request)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, "att-queued")
    }

    func testFetchAttachments_filtersByQueuedOrFailed() throws {
        // Create attachments with different states
        let _ = AttachmentBuilder()
            .withId("att-queued")
            .queued()
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-downloaded")
            .downloaded()
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-failed")
            .failed()
            .build(in: context)

        try testStack.saveViewContext()

        // Fetch queued or failed (downloadable attachments)
        let request = Attachment.fetchRequest()
        request.predicate = NSPredicate(format: "stateRaw == %@ OR stateRaw == %@", "queued", "failed")

        let results = try context.fetch(request)

        XCTAssertEqual(results.count, 2)
        let ids = Set(results.compactMap { $0.id })
        XCTAssertTrue(ids.contains("att-queued"))
        XCTAssertTrue(ids.contains("att-failed"))
    }

    // MARK: - isImage / isPDF Tests

    func testAttachment_isImage_returnsCorrectly() throws {
        let jpegAttachment = AttachmentBuilder()
            .withMimeType("image/jpeg")
            .build(in: context)
        XCTAssertTrue(jpegAttachment.isImage)

        let pngAttachment = AttachmentBuilder()
            .withMimeType("image/png")
            .build(in: context)
        XCTAssertTrue(pngAttachment.isImage)

        let pdfAttachment = AttachmentBuilder()
            .withMimeType("application/pdf")
            .build(in: context)
        XCTAssertFalse(pdfAttachment.isImage)

        let textAttachment = AttachmentBuilder()
            .withMimeType("text/plain")
            .build(in: context)
        XCTAssertFalse(textAttachment.isImage)
    }

    func testAttachment_isPDF_returnsCorrectly() throws {
        let pdfAttachment = AttachmentBuilder()
            .withMimeType("application/pdf")
            .build(in: context)
        XCTAssertTrue(pdfAttachment.isPDF)

        let imageAttachment = AttachmentBuilder()
            .withMimeType("image/jpeg")
            .build(in: context)
        XCTAssertFalse(imageAttachment.isPDF)
    }

    // MARK: - Signature Image Detection Tests

    func testAttachment_isLikelySignatureImage_smallByteSize() throws {
        // Attachment under 10KB should be detected as likely signature
        let smallAttachment = AttachmentBuilder()
            .asImage(width: 200, height: 100)
            .withByteSize(5000) // 5KB
            .build(in: context)

        XCTAssertTrue(smallAttachment.isLikelySignatureImage, "Small image under 10KB should be likely signature")
    }

    func testAttachment_isLikelySignatureImage_smallDimensions() throws {
        // Attachment with both dimensions <= 100px should be detected as likely signature
        let smallDimensionsAttachment = AttachmentBuilder()
            .asImage(width: 80, height: 80)
            .withByteSize(50000) // 50KB - larger than threshold
            .build(in: context)

        XCTAssertTrue(smallDimensionsAttachment.isLikelySignatureImage, "Image with dimensions <= 100px should be likely signature")
    }

    func testAttachment_isLikelySignatureImage_largeImageIsNotSignature() throws {
        // Normal-sized image should not be detected as signature
        let normalAttachment = AttachmentBuilder()
            .asImage(width: 800, height: 600)
            .withByteSize(500000) // 500KB
            .build(in: context)

        XCTAssertFalse(normalAttachment.isLikelySignatureImage, "Normal sized image should not be detected as signature")
    }

    func testAttachment_isLikelySignatureImage_nonImageIsNotSignature() throws {
        // Non-image attachment should not be detected as signature
        let pdfAttachment = AttachmentBuilder()
            .asPDF()
            .withByteSize(5000) // Small but not an image
            .build(in: context)

        XCTAssertFalse(pdfAttachment.isLikelySignatureImage, "Non-image attachment should not be detected as signature")
    }

    // MARK: - displayableAttachments Tests

    func testMessage_displayableAttachments_filtersSignatureImages() throws {
        let message = MessageBuilder()
            .withId("msg-with-attachments")
            .withAttachments()
            .build(in: context)

        // Add a normal image
        let _ = AttachmentBuilder()
            .withId("att-normal")
            .asImage(width: 800, height: 600)
            .withByteSize(100000)
            .forMessage(message)
            .build(in: context)

        // Add a signature image (small bytes)
        let _ = AttachmentBuilder()
            .withId("att-signature")
            .asImage(width: 200, height: 50)
            .withByteSize(5000) // Under 10KB
            .forMessage(message)
            .build(in: context)

        try testStack.saveViewContext()

        // Fetch fresh message
        let fetchedMessage = try context.existingObject(with: message.objectID) as? Message

        let displayable = fetchedMessage?.displayableAttachments ?? []

        // Should only include the normal image, not the signature
        XCTAssertEqual(displayable.count, 1)
        XCTAssertEqual(displayable.first?.id, "att-normal")
    }

    // MARK: - Local Attachment Tests

    func testAttachment_isLocalAttachment_detectsLocalIds() throws {
        // Local attachments have IDs starting with "local_" (underscore, not hyphen)
        let localAttachment = AttachmentBuilder()
            .withId("local_uuid-123")
            .build(in: context)

        XCTAssertTrue(localAttachment.isLocalAttachment)

        let remoteAttachment = AttachmentBuilder()
            .withId("gmail-attachment-456")
            .build(in: context)

        XCTAssertFalse(remoteAttachment.isLocalAttachment)
    }

    // MARK: - Batch Size Tests

    func testFetchAttachments_usesBatchSize() throws {
        // Create many attachments
        for i in 0..<100 {
            let _ = AttachmentBuilder()
                .withId("att-\(i)")
                .queued()
                .build(in: context)
        }

        try testStack.saveViewContext()

        // Fetch with batch size (like AttachmentDownloader does)
        let request = Attachment.fetchRequest()
        request.predicate = NSPredicate(format: "stateRaw == %@", "queued")
        request.fetchBatchSize = 10

        let results = try context.fetch(request)

        XCTAssertEqual(results.count, 100)
    }

    // MARK: - Cleanup Tests

    func testCollectingValidFilePaths_fromAttachments() throws {
        // Create attachments with file paths
        let _ = AttachmentBuilder()
            .withId("att-1")
            .downloaded()
            .withLocalURL("Attachments/file1.jpg")
            .withPreviewURL("Previews/file1.jpg")
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-2")
            .downloaded()
            .withLocalURL("Attachments/file2.pdf")
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-3")
            .queued() // No files yet
            .build(in: context)

        try testStack.saveViewContext()

        // Collect valid file paths (like cleanupOrphanedFiles does)
        let request = Attachment.fetchRequest()
        let attachments = try context.fetch(request)

        let validFiles = Set(attachments.compactMap { attachment -> [String] in
            var files: [String] = []
            if let localURL = attachment.localURL {
                files.append(localURL)
            }
            if let previewURL = attachment.previewURL {
                files.append(previewURL)
            }
            return files
        }.flatMap { $0 })

        XCTAssertEqual(validFiles.count, 3)
        XCTAssertTrue(validFiles.contains("Attachments/file1.jpg"))
        XCTAssertTrue(validFiles.contains("Previews/file1.jpg"))
        XCTAssertTrue(validFiles.contains("Attachments/file2.pdf"))
    }
}
