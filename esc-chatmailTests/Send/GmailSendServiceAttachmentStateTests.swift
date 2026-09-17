import XCTest
import CoreData
@testable import esc_chatmail

/// Every fixture, save, and assertion goes through the suite's `viewContext`, a
/// main-queue context from `TestCoreDataStack.makeMainQueueViewContext()`,
/// never `coreDataStack.viewContext`, which is private-queue.
/// `GmailSendService` is `@MainActor` and fetches and saves its context
/// directly, which is on-queue only for a main-queue context. See that helper
/// for what the private-queue shape races.
///
/// HONEST SCOPE: no test here can reproduce that race on demand. With
/// `-com.apple.CoreData.ConcurrencyDebug 1` the old shape traps and this shape
/// runs clean.
@MainActor
final class GmailSendServiceAttachmentStateTests: XCTestCase {
    private var coreDataStack: TestCoreDataStack!
    private var viewContext: NSManagedObjectContext!
    private var sendService: GmailSendService!

    override func setUp() {
        super.setUp()
        coreDataStack = TestCoreDataStack()
        viewContext = coreDataStack.makeMainQueueViewContext()
        sendService = GmailSendService(viewContext: viewContext)
    }

    override func tearDown() {
        sendService = nil
        viewContext = nil
        coreDataStack = nil
        super.tearDown()
    }

    func testMarkAttachmentsAsUploadingAndUploaded_resolvesLocalAttachmentReferences() throws {
        let context: NSManagedObjectContext = viewContext
        let attachment = AttachmentBuilder()
            .withId("local_attachment_1")
            .withFilename("photo.jpg")
            .withMimeType("image/jpeg")
            .withLocalURL("Attachments/photo.jpg")
            .queued()
            .build(in: context)
        try saveViewContext()

        let attachmentReference = LocalAttachmentReference(objectID: attachment.objectID)

        sendService.markAttachmentsAsUploading(references: [attachmentReference])
        XCTAssertEqual(attachment.state, .uploading)

        sendService.markAttachmentsAsUploaded(references: [attachmentReference])
        XCTAssertEqual(attachment.state, .uploaded)
    }

    func testHandleFailedOptimisticMessageByID_marksFallbackAttachmentsFailed() throws {
        let context: NSManagedObjectContext = viewContext
        let attachment = AttachmentBuilder()
            .withId("local_attachment_2")
            .withFilename("doc.pdf")
            .withMimeType("application/pdf")
            .withLocalURL("Attachments/doc.pdf")
            .downloading()
            .build(in: context)
        try saveViewContext()

        sendService.handleFailedOptimisticMessage(
            byID: "missing-optimistic-message",
            fallbackAttachmentReferences: [LocalAttachmentReference(objectID: attachment.objectID)]
        )

        XCTAssertEqual(attachment.state, .failed)
    }

    /// Saves the suite's main-queue context directly; the test body is
    /// already on its queue. `TestCoreDataStack.saveViewContext()` would save
    /// the stack's private-queue context instead (see the type comment).
    private func saveViewContext() throws {
        guard viewContext.hasChanges else { return }
        try viewContext.save()
    }
}
