import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class ParticipantLoaderTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        context = stack.viewContext
    }

    override func tearDown() {
        context = nil
        stack = nil
        super.tearDown()
    }

    func testExtractNonMeParticipants_excludesHideMyEmailRelay() throws {
        let conversation = ConversationBuilder()
            .withDisplayName("San, Hide")
            .build(in: context)

        let sender = PersonBuilder()
            .withEmail("tickets@sfballet.org")
            .withDisplayName("San Francisco Ballet")
            .build(in: context)

        let hideRelay = PersonBuilder()
            .withEmail("thud-others-1n@icloud.com")
            .withDisplayName("Hide My Email")
            .build(in: context)

        let me = PersonBuilder()
            .withEmail("kmthau@gmail.com")
            .withDisplayName("Kevin Thau")
            .build(in: context)

        addConversationParticipant(person: sender, to: conversation)
        addConversationParticipant(person: hideRelay, to: conversation)
        addConversationParticipant(person: me, to: conversation)
        try context.save()

        let emails = ParticipantLoader.shared.extractNonMeParticipants(
            from: conversation,
            currentUserEmail: "kmthau@gmail.com"
        )

        XCTAssertEqual(emails, ["tickets@sfballet.org"])
    }

    func testLoadParticipants_deletedConversationObjectID_returnsFallback() async throws {
        let conversation = ConversationBuilder()
            .withDisplayName("Fallback Name")
            .build(in: context)
        try context.save()

        let conversationObjectID = conversation.objectID
        context.delete(conversation)
        try context.save()

        let info = await ParticipantLoader.shared.loadParticipants(
            from: conversationObjectID,
            in: context,
            currentUserEmail: "kmthau@gmail.com",
            maxParticipants: 4,
            fallbackDisplayName: "Fallback Name"
        )

        XCTAssertEqual(info.emails, [])
        XCTAssertEqual(info.displayNames, [])
        XCTAssertEqual(info.photos.count, 0)
        XCTAssertEqual(info.formattedDisplayName, "Fallback Name")
    }

    private func addConversationParticipant(person: Person, to conversation: Conversation) {
        let participant = ConversationParticipant(context: context)
        participant.id = UUID()
        participant.participantRole = .normal
        participant.person = person
        participant.conversation = conversation
    }
}
