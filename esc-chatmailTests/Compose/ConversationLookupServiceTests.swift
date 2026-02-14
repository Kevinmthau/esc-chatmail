import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class ConversationLookupServiceTests: XCTestCase {

    private var testStack: TestCoreDataStack!
    private var context: NSManagedObjectContext!
    private var service: ConversationLookupService!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        context = testStack.viewContext
        service = ConversationLookupService(context: context)
    }

    override func tearDown() {
        service = nil
        context = nil
        testStack = nil
        super.tearDown()
    }

    func testFindActiveConversation_returnsMatchingActiveConversation() throws {
        let recipient = "user.name+promo@googlemail.com"
        let participantHash = calculateParticipantHash(from: [EmailNormalizer.normalize(recipient)])

        let expectedConversation = ConversationBuilder()
            .withParticipantHash(participantHash)
            .withDisplayName("Expected")
            .visible()
            .build(in: context)

        _ = ConversationBuilder()
            .withParticipantHash("different-hash")
            .withDisplayName("Other")
            .visible()
            .build(in: context)

        try testStack.saveViewContext()

        let result = service.findActiveConversation(forRecipients: ["USER.NAME@GMAIL.COM"])

        XCTAssertEqual(result?.objectID, expectedConversation.objectID)
    }

    func testFindActiveConversation_ignoresArchivedConversation() throws {
        let recipient = "person@example.com"
        let participantHash = calculateParticipantHash(from: [EmailNormalizer.normalize(recipient)])

        _ = ConversationBuilder()
            .withParticipantHash(participantHash)
            .withDisplayName("Archived")
            .archived()
            .build(in: context)

        try testStack.saveViewContext()

        let result = service.findActiveConversation(forRecipients: [recipient])

        XCTAssertNil(result)
    }

    func testFindActiveConversation_normalizesAndDeduplicatesRecipientSet() throws {
        let recipients = ["alice@example.com", "bob@example.com"]
        let participantHash = calculateParticipantHash(from: recipients)

        let expectedConversation = ConversationBuilder()
            .withParticipantHash(participantHash)
            .withDisplayName("Group")
            .visible()
            .build(in: context)

        try testStack.saveViewContext()

        let result = service.findActiveConversation(
            forRecipients: ["BOB@example.com", "alice@example.com", "alice@example.com"]
        )

        XCTAssertEqual(result?.objectID, expectedConversation.objectID)
    }
}
