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

    func testAttachment_isVideo_returnsCorrectly() throws {
        let mp4Attachment = AttachmentBuilder()
            .withMimeType("video/mp4")
            .build(in: context)
        XCTAssertTrue(mp4Attachment.isVideo)

        let movAttachment = AttachmentBuilder()
            .withMimeType("video/quicktime")
            .build(in: context)
        XCTAssertTrue(movAttachment.isVideo)

        let pdfAttachment = AttachmentBuilder()
            .withMimeType("application/pdf")
            .build(in: context)
        XCTAssertFalse(pdfAttachment.isVideo)
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

    func testMessage_displayableAttachments_hidingInlineReferencedInHTML_filtersCIDReferencedInlineImages() throws {
        let messageId = "msg-inline-filter-\(UUID().uuidString)"
        let message = MessageBuilder()
            .withId(messageId)
            .withAttachments()
            .build(in: context)

        // Attachment referenced by cid: in HTML should be hidden when `hidingInlineReferencedInHTML` is true.
        let _ = AttachmentBuilder()
            .withId("att-inline")
            .withFilename("inline.jpg")
            .withContentId("CID_INLINE")
            .asImage(width: 800, height: 600)
            .withByteSize(100000)
            .forMessage(message)
            .build(in: context)

        // Attachment not referenced by cid: should remain visible.
        let _ = AttachmentBuilder()
            .withId("att-regular")
            .withFilename("regular.jpg")
            .withContentId("CID_OTHER")
            .asImage(width: 800, height: 600)
            .withByteSize(100000)
            .forMessage(message)
            .build(in: context)

        let handler = HTMLContentHandler.shared
        _ = handler.saveHTML("<html><body><img src=\"cid:CID_INLINE\"></body></html>", for: messageId)

        try testStack.saveViewContext()

        let fetchedMessage = try context.existingObject(with: message.objectID) as? Message
        let hiddenInline = fetchedMessage?.displayableAttachments(hidingInlineReferencedInHTML: true) ?? []
        XCTAssertEqual(hiddenInline.compactMap { $0.id }.sorted(), ["att-regular"])

        let showAll = fetchedMessage?.displayableAttachments(hidingInlineReferencedInHTML: false) ?? []
        XCTAssertEqual(showAll.compactMap { $0.id }.sorted(), ["att-inline", "att-regular"])

        handler.deleteHTML(for: messageId)
    }

    func testMessage_displayableAttachments_hidesCalendarInviteFilesOnlyInPreviewMode() throws {
        let message = MessageBuilder()
            .withSubject("Invitation: Board sync @ Mon May 5, 2026 9:00am - 9:30am (EDT)")
            .withSnippet("Invitation from Google Calendar")
            .withBody(
                """
                Invitation from Google Calendar
                Board sync
                When
                Monday May 5, 2026 • 9:00am – 9:30am (Eastern Time - New York)
                Guests
                brynn@example.com
                Reply for kmthau@gmail.com
                """
            )
            .withAttachments()
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-calendar")
            .withFilename("invite.ics")
            .withMimeType("text/calendar")
            .withByteSize(2_048)
            .forMessage(message)
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-notes")
            .withFilename("notes.pdf")
            .asPDF()
            .withByteSize(45_000)
            .forMessage(message)
            .build(in: context)

        try testStack.saveViewContext()

        let fetchedMessage = try context.existingObject(with: message.objectID) as? Message

        let previewAttachments = fetchedMessage?.displayableAttachments(hidingInlineReferencedInHTML: true) ?? []
        XCTAssertEqual(previewAttachments.compactMap { $0.id }, ["att-notes"])

        let bubbleAttachments = fetchedMessage?.displayableAttachments(hidingInlineReferencedInHTML: false) ?? []
        XCTAssertEqual(bubbleAttachments.compactMap { $0.id }.sorted(), ["att-calendar", "att-notes"])
    }

    func testMessage_displayableAttachments_plainBubble_hidesSignatureOnlyCIDInlineImages() throws {
        let messageId = "msg-inline-signature-\(UUID().uuidString)"
        let message = MessageBuilder()
            .withId(messageId)
            .withAttachments()
            .build(in: context)

        // Signature/logo CID image should be hidden even in plain bubble mode.
        let _ = AttachmentBuilder()
            .withId("att-signature-inline")
            .withFilename("image001.png")
            .withContentId("image001.png@01DC96AF.8C2488C0")
            .asImage(width: 512, height: 512) // Not caught by size/dimension signature heuristic alone
            .withByteSize(31_639)
            .forMessage(message)
            .build(in: context)

        // Real inline body image should still be shown in plain bubble mode.
        let _ = AttachmentBuilder()
            .withId("att-body-inline")
            .withFilename("site-photo.png")
            .withContentId("body-inline-image")
            .asImage(width: 1200, height: 900)
            .withByteSize(350_000)
            .forMessage(message)
            .build(in: context)

        // Regular non-inline attachment should always remain visible.
        let _ = AttachmentBuilder()
            .withId("att-regular-file")
            .withFilename("notes.pdf")
            .asPDF()
            .withByteSize(45_000)
            .forMessage(message)
            .build(in: context)

        let handler = HTMLContentHandler.shared
        _ = handler.saveHTML(
            """
            <html><body>
            <div>Hope everyone had a good week!</div>
            <div><img src="cid:body-inline-image"></div>
            <div id="ms-outlook-mobile-signature">
                <p>Ally Varady</p>
                <p><img src="cid:image001.png@01DC96AF.8C2488C0"></p>
            </div>
            </body></html>
            """,
            for: messageId
        )

        try testStack.saveViewContext()

        let fetchedMessage = try context.existingObject(with: message.objectID) as? Message
        let displayable = fetchedMessage?.displayableAttachments(hidingInlineReferencedInHTML: false) ?? []

        XCTAssertEqual(displayable.compactMap { $0.id }.sorted(), ["att-body-inline", "att-regular-file"])

        handler.deleteHTML(for: messageId)
    }

    func testMessage_displayableAttachments_plainBubble_hidesOutlookWordSignatureLogoWithoutWrapper() throws {
        let messageId = "msg-inline-outlook-word-signature-\(UUID().uuidString)"
        let message = MessageBuilder()
            .withId(messageId)
            .withAttachments()
            .build(in: context)

        // Outlook/Word signature logo (generic image001 filename + CID) should not show as attachment.
        let _ = AttachmentBuilder()
            .withId("att-signature-word-inline")
            .withFilename("image001.png")
            .withContentId("image001.png@01DCA5AF.35846080")
            .asImage(width: 134, height: 53)
            .withByteSize(192_520)
            .forMessage(message)
            .build(in: context)

        // Real file attachment should remain visible.
        let _ = AttachmentBuilder()
            .withId("att-real-file")
            .withFilename("ABT x Casa Tua Invitation.png")
            .asImage(width: 1024, height: 1536)
            .withByteSize(3_467_325)
            .forMessage(message)
            .build(in: context)

        let handler = HTMLContentHandler.shared
        _ = handler.saveHTML(
            """
            <html><body>
            <div>Hi Brynn and Kevin,</div>
            <div>I hope that you are staying warm and doing well!</div>
            <div>Warmly,</div>
            <div>Katherine</div>
            <div><strong>Katherine Merwin</strong></div>
            <div>Global Membership Manager</div>
            <div><img src="cid:image001.png@01DCA5AF.35846080" alt="logo"></div>
            </body></html>
            """,
            for: messageId
        )

        try testStack.saveViewContext()

        let fetchedMessage = try context.existingObject(with: message.objectID) as? Message
        let displayable = fetchedMessage?.displayableAttachments(hidingInlineReferencedInHTML: false) ?? []

        XCTAssertEqual(displayable.compactMap { $0.id }.sorted(), ["att-real-file"])

        handler.deleteHTML(for: messageId)
    }

    func testMessage_displayableAttachments_plainBubble_usesBodyStorageURIHTMLFallback() throws {
        let messageId = "msg-inline-body-storage-uri-fallback-\(UUID().uuidString)"
        let message = MessageBuilder()
            .withId(messageId)
            .withAttachments()
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-signature-uri-inline")
            .asImage(width: 134, height: 53)
            .withFilename("image001.png")
            .withContentId("image001.png@01DCA5AF.35846080")
            .withByteSize(192_520)
            .forMessage(message)
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-real-uri-file")
            .asImage(width: 1024, height: 1536)
            .withFilename("ABT x Casa Tua Invitation.png")
            .withByteSize(3_467_325)
            .forMessage(message)
            .build(in: context)

        let html = """
        <html><body>
        <div>Hi Brynn and Kevin,</div>
        <div>I hope that you are staying warm and doing well!</div>
        <div>Warmly,</div>
        <div>Katherine</div>
        <div><strong>Katherine Merwin</strong></div>
        <div>Global Membership Manager</div>
        <div><img src="cid:image001.png@01DCA5AF.35846080" alt="logo"></div>
        </body></html>
        """

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("body-storage-fallback-\(UUID().uuidString).html")
        try html.write(to: tempURL, atomically: true, encoding: .utf8)

        let handler = HTMLContentHandler.shared
        handler.deleteHTML(for: messageId)
        message.bodyStorageURI = tempURL.absoluteString

        try testStack.saveViewContext()

        let fetchedMessage = try context.existingObject(with: message.objectID) as? Message
        let displayable = fetchedMessage?.displayableAttachments(hidingInlineReferencedInHTML: false) ?? []

        XCTAssertEqual(displayable.compactMap { $0.id }.sorted(), ["att-real-uri-file"])

        try? FileManager.default.removeItem(at: tempURL)
    }

    func testMessage_displayableAttachments_plainBubble_doesNotHideInlineForGenericDomainMention() throws {
        let messageId = "msg-inline-generic-domain-mention-\(UUID().uuidString)"
        let message = MessageBuilder()
            .withId(messageId)
            .withAttachments()
            .build(in: context)

        let _ = AttachmentBuilder()
            .withId("att-inline-body-image")
            .withFilename("image001.png")
            .withContentId("image001.png@01DCA5AF.35846080")
            .asImage(width: 220, height: 90)
            .withByteSize(192_520)
            .forMessage(message)
            .build(in: context)

        let handler = HTMLContentHandler.shared
        _ = handler.saveHTML(
            """
            <html><body>
            <div><img src="cid:image001.png@01DCA5AF.35846080" alt="hero"></div>
            <div>Warmly,</div>
            <div>Please see details at casatualife.com/events</div>
            </body></html>
            """,
            for: messageId
        )

        try testStack.saveViewContext()

        let fetchedMessage = try context.existingObject(with: message.objectID) as? Message
        let displayable = fetchedMessage?.displayableAttachments(hidingInlineReferencedInHTML: false) ?? []

        XCTAssertEqual(displayable.compactMap { $0.id }.sorted(), ["att-inline-body-image"])

        handler.deleteHTML(for: messageId)
    }

    func testMessage_displayableAttachments_plainBubble_deduplicatesRepeatedInlineContentIDs() throws {
        let messageId = "msg-inline-duplicate-cid-\(UUID().uuidString)"
        let message = MessageBuilder()
            .withId(messageId)
            .withAttachments()
            .build(in: context)

        for suffix in 1...3 {
            let _ = AttachmentBuilder()
                .withId("att-inline-dup-\(suffix)")
                .withFilename("IMG_6161.jpeg")
                .withContentId("6AFCA8C9-D2EF-4407-BD15-8D9F042220E9")
                .asImage(width: 1200, height: 1200)
                .withByteSize(350_000)
                .forMessage(message)
                .build(in: context)
        }

        let handler = HTMLContentHandler.shared
        _ = handler.saveHTML(
            """
            <html><body>
            <img src="cid:6AFCA8C9-D2EF-4407-BD15-8D9F042220E9" alt="IMG_6161.jpeg">
            <div><strong>RICK THAU</strong></div>
            <div>Carmel, CA</div>
            </body></html>
            """,
            for: messageId
        )

        try testStack.saveViewContext()

        let fetchedMessage = try context.existingObject(with: message.objectID) as? Message
        let displayable = fetchedMessage?.displayableAttachments(hidingInlineReferencedInHTML: false) ?? []

        XCTAssertEqual(displayable.count, 1)
        XCTAssertEqual(displayable.first?.contentId, "6AFCA8C9-D2EF-4407-BD15-8D9F042220E9")

        handler.deleteHTML(for: messageId)
    }

    func testMessage_displayableAttachments_plainBubble_deduplicatesRepeatedRegularFiles() throws {
        let message = MessageBuilder()
            .withId("msg-duplicate-regular-files-\(UUID().uuidString)")
            .withAttachments()
            .build(in: context)

        for suffix in 1...2 {
            let _ = AttachmentBuilder()
                .withId("att-invoice-dup-\(suffix)")
                .withFilename("Invoice-4B07C32C-0025.pdf")
                .withMimeType("application/pdf")
                .withByteSize(91_248)
                .forMessage(message)
                .build(in: context)
        }

        for suffix in 1...2 {
            let _ = AttachmentBuilder()
                .withId("att-receipt-dup-\(suffix)")
                .withFilename("Receipt-2243-8647-5708.pdf")
                .withMimeType("application/pdf")
                .withByteSize(88_032)
                .forMessage(message)
                .build(in: context)
        }

        try testStack.saveViewContext()

        let fetchedMessage = try context.existingObject(with: message.objectID) as? Message
        let displayable = fetchedMessage?.displayableAttachments(hidingInlineReferencedInHTML: false) ?? []

        XCTAssertEqual(displayable.count, 2)
        XCTAssertEqual(displayable.map(\.filename).sorted(), [
            "Invoice-4B07C32C-0025.pdf",
            "Receipt-2243-8647-5708.pdf"
        ])
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
