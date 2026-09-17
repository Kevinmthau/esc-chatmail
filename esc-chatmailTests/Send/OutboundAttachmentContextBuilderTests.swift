import XCTest
import CoreData
@testable import esc_chatmail

/// Every fixture and assertion goes through the suite's `viewContext`, a
/// main-queue context from `TestCoreDataStack.makeMainQueueViewContext()`,
/// never `coreDataStack.viewContext`, which is private-queue.
/// `OutboundAttachmentContextBuilder` is `@MainActor` and obtains permanent IDs
/// on its context directly, which is on-queue only for a main-queue context.
/// See that helper for what the private-queue shape races.
///
/// HONEST SCOPE: no test here can reproduce that race on demand. With
/// `-com.apple.CoreData.ConcurrencyDebug 1` the old shape traps and this shape
/// runs clean.
@MainActor
final class OutboundAttachmentContextBuilderTests: XCTestCase {
    private var coreDataStack: TestCoreDataStack!
    private var viewContext: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        coreDataStack = TestCoreDataStack()
        viewContext = coreDataStack.makeMainQueueViewContext()
    }

    override func tearDown() {
        viewContext = nil
        coreDataStack = nil
        super.tearDown()
    }

    func testBuildSendAttachments_promotesTemporaryIDsAndCapturesAttachmentInfo() throws {
        let context: NSManagedObjectContext = viewContext
        let builder = OutboundAttachmentContextBuilder(viewContext: context)

        let attachment = context.insertTestObject(Attachment.self)
        attachment.id = "local_attachment_1"
        attachment.filename = "photo.jpg"
        attachment.mimeType = "image/jpeg"
        attachment.localURL = "Attachments/photo.jpg"
        attachment.previewURL = "Previews/photo.jpg"
        attachment.stateRaw = Attachment.State.queued.rawValue

        XCTAssertTrue(attachment.objectID.isTemporaryID)

        let contexts = try builder.buildSendAttachments(from: [attachment])

        XCTAssertFalse(attachment.objectID.isTemporaryID)
        XCTAssertEqual(contexts.map(\.info.filename), ["photo.jpg"])
        XCTAssertEqual(contexts.map(\.info.mimeType), ["image/jpeg"])
        XCTAssertEqual(
            contexts.map(\.localAttachmentReference),
            [LocalAttachmentReference(objectID: attachment.objectID)]
        )
    }

    func testBuildSendAttachments_rejectsUnfinishedPlaceholderBeforePromotingObjectID() throws {
        let context: NSManagedObjectContext = viewContext
        let builder = OutboundAttachmentContextBuilder(viewContext: context)
        let attachment = context.insertTestObject(Attachment.self)
        attachment.id = "local_unfinished"
        attachment.filename = "photo.jpg"
        attachment.mimeType = "image/jpeg"
        attachment.stateRaw = Attachment.State.queued.rawValue

        XCTAssertThrowsError(try builder.buildSendAttachments(from: [attachment])) { error in
            XCTAssertEqual(
                error as? OutboundAttachmentContextBuilder.BuildError,
                .attachmentNotReady(filename: "photo.jpg")
            )
        }
        XCTAssertTrue(
            attachment.objectID.isTemporaryID,
            "Rejected placeholders must not mutate the draft's Core Data identity"
        )
    }

    func testBuildersRejectLegacyRemotePathForForwardingOrSend() throws {
        let context: NSManagedObjectContext = viewContext
        let builder = OutboundAttachmentContextBuilder(viewContext: context)
        let message = MessageBuilder()
            .withId("forward-source")
            .withAttachments()
            .build(in: context)
        let attachmentID = "legacy-forward-attachment"
        let attachment = AttachmentBuilder()
            .withId(attachmentID)
            .withFilename("inline.png")
            .withMimeType("image/png")
            .withContentId("inline@example.com")
            .withLocalURL(AttachmentPaths.originalPath(idOrUUID: attachmentID, ext: "png"))
            .downloaded()
            .forMessage(message)
            .build(in: context)

        XCTAssertThrowsError(try builder.buildSendAttachments(from: [attachment])) { error in
            XCTAssertEqual(
                error as? OutboundAttachmentContextBuilder.BuildError,
                .attachmentNotReady(filename: "inline.png")
            )
        }

        XCTAssertThrowsError(try builder.buildInlineAttachmentInfos(from: [attachment])) { error in
            XCTAssertEqual(
                error as? OutboundAttachmentContextBuilder.BuildError,
                .attachmentNotReady(filename: "inline.png")
            )
        }
    }
}
