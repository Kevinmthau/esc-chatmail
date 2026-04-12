import XCTest
@testable import esc_chatmail

@MainActor
final class GmailSendServiceAttachmentStateTests: XCTestCase {
    private var coreDataStack: TestCoreDataStack!
    private var sendService: GmailSendService!

    override func setUp() {
        super.setUp()
        coreDataStack = TestCoreDataStack()
        sendService = GmailSendService(viewContext: coreDataStack.viewContext)
    }

    override func tearDown() {
        sendService = nil
        coreDataStack = nil
        super.tearDown()
    }

    func testMarkAttachmentsAsUploadingAndUploaded_resolvesLocalAttachmentReferences() throws {
        let context = coreDataStack.viewContext
        let attachment = AttachmentBuilder()
            .withId("local_attachment_1")
            .withFilename("photo.jpg")
            .withMimeType("image/jpeg")
            .withLocalURL("Attachments/photo.jpg")
            .queued()
            .build(in: context)
        try coreDataStack.saveViewContext()

        let attachmentReference = LocalAttachmentReference(objectID: attachment.objectID)

        sendService.markAttachmentsAsUploading(references: [attachmentReference])
        XCTAssertEqual(attachment.state, .uploading)

        sendService.markAttachmentsAsUploaded(references: [attachmentReference])
        XCTAssertEqual(attachment.state, .uploaded)
    }

    func testHandleFailedOptimisticMessageByID_marksFallbackAttachmentsFailed() throws {
        let context = coreDataStack.viewContext
        let attachment = AttachmentBuilder()
            .withId("local_attachment_2")
            .withFilename("doc.pdf")
            .withMimeType("application/pdf")
            .withLocalURL("Attachments/doc.pdf")
            .downloading()
            .build(in: context)
        try coreDataStack.saveViewContext()

        sendService.handleFailedOptimisticMessage(
            byID: "missing-optimistic-message",
            fallbackAttachmentReferences: [LocalAttachmentReference(objectID: attachment.objectID)]
        )

        XCTAssertEqual(attachment.state, .failed)
    }
}
