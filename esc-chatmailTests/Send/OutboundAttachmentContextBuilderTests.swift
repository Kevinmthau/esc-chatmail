import XCTest
@testable import esc_chatmail

@MainActor
final class OutboundAttachmentContextBuilderTests: XCTestCase {
    private var coreDataStack: TestCoreDataStack!

    override func setUp() {
        super.setUp()
        coreDataStack = TestCoreDataStack()
    }

    override func tearDown() {
        coreDataStack = nil
        super.tearDown()
    }

    func testBuildSendAttachments_promotesTemporaryIDsAndCapturesAttachmentInfo() throws {
        let context = coreDataStack.viewContext
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
        let context = coreDataStack.viewContext
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
        let context = coreDataStack.viewContext
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
