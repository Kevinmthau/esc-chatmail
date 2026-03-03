import XCTest
@testable import esc_chatmail

@MainActor
final class GmailSendServiceOptimisticFailureTests: XCTestCase {
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

    func testHandleFailedOptimisticMessage_withoutLocalAttachments_deletesOptimisticMessage() throws {
        let context = coreDataStack.viewContext
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: context)

        let messageID = "optimistic-no-attachments"
        let message = MessageBuilder()
            .withId(messageID)
            .fromMe()
            .inConversation(conversation)
            .build(in: context)

        try coreDataStack.saveViewContext()
        XCTAssertNotNil(sendService.fetchMessageSync(byID: messageID))

        sendService.handleFailedOptimisticMessage(message)

        XCTAssertNil(sendService.fetchMessageSync(byID: messageID))
    }

    func testHandleFailedOptimisticMessage_withLocalAttachments_marksOnlyLocalAttachmentsFailed() throws {
        let context = coreDataStack.viewContext
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: context)

        let messageID = "optimistic-with-attachments"
        let message = MessageBuilder()
            .withId(messageID)
            .fromMe()
            .withAttachments()
            .inConversation(conversation)
            .build(in: context)

        let localAttachmentID = "local_attachment_1"
        _ = AttachmentBuilder()
            .withId(localAttachmentID)
            .downloading()
            .forMessage(message)
            .build(in: context)

        let remoteAttachmentID = "gmail_attachment_1"
        _ = AttachmentBuilder()
            .withId(remoteAttachmentID)
            .downloaded()
            .forMessage(message)
            .build(in: context)

        try coreDataStack.saveViewContext()

        sendService.handleFailedOptimisticMessage(message)

        let persisted = try XCTUnwrap(sendService.fetchMessageSync(byID: messageID))
        let localAttachment = try XCTUnwrap(persisted.attachmentsArray.first { $0.id == localAttachmentID })
        let remoteAttachment = try XCTUnwrap(persisted.attachmentsArray.first { $0.id == remoteAttachmentID })

        XCTAssertEqual(localAttachment.state, .failed)
        XCTAssertEqual(remoteAttachment.state, .downloaded)
    }
}
