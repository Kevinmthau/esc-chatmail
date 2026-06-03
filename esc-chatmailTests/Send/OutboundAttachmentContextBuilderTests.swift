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
}
