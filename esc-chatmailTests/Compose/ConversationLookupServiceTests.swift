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

        let result = service.findActiveConversation(forRecipients: ["USER.NAME@GMAIL.COM"], myAliases: [])

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

        let result = service.findActiveConversation(forRecipients: [recipient], myAliases: [])

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
            forRecipients: ["BOB@example.com", "alice@example.com", "alice@example.com"],
            myAliases: []
        )

        XCTAssertEqual(result?.objectID, expectedConversation.objectID)
    }

    // MARK: - Compose/sync hash parity

    /// A recipient list that includes one of the user's own aliases must hash to
    /// the same conversation the synced-back copy of the send will route to
    /// (sync identity excludes self-aliases). Discriminator for the strict-keying
    /// compose parity fix: without alias exclusion the lookup misses.
    func testFindActiveConversation_excludesOwnAliasFromRecipientSet() throws {
        let myAlias = "me@example.com"
        let recipient = "paul@example.com"
        // The sync router keys this chat by {paul} only.
        let participantHash = calculateParticipantHash(from: [recipient])

        let expectedConversation = ConversationBuilder()
            .withParticipantHash(participantHash)
            .withDisplayName("Paul")
            .visible()
            .build(in: context)

        try testStack.saveViewContext()

        let result = service.findActiveConversation(
            forRecipients: [recipient, myAlias],
            myAliases: [myAlias]
        )

        XCTAssertEqual(result?.objectID, expectedConversation.objectID)
    }

    /// Recipient lists that are all self-aliases must resolve to the same
    /// deterministic self-conversation key the sync path produces.
    func testFindActiveConversation_selfOnlyRecipientsUseDeterministicSelfKey() throws {
        let aliases: Set<String> = ["me@example.com", "alias@example.com"]
        // makeParticipantSetIdentity's self-fallback: sorted-first alias.
        let participantHash = calculateParticipantHash(from: ["alias@example.com"])

        let expectedConversation = ConversationBuilder()
            .withParticipantHash(participantHash)
            .withDisplayName("Me")
            .visible()
            .build(in: context)

        try testStack.saveViewContext()

        let result = service.findActiveConversation(
            forRecipients: ["me@example.com"],
            myAliases: aliases
        )

        XCTAssertEqual(result?.objectID, expectedConversation.objectID)
    }

    /// Compose-side hashes must match the sync-side header derivation exactly for
    /// the same people — including gmail dot/plus canonicalization and alias
    /// exclusion. Guards against the two paths drifting apart.
    func testRecipientIdentityMatchesHeaderIdentity() {
        let myAliases: Set<String> = ["me@example.com"]
        let recipients = ["K.evin+news@GoogleMail.com", "Paul@Example.com", "me@example.com"]

        let headers = [MessageHeader(name: "From", value: "me@example.com")]
            + recipients.map { MessageHeader(name: "To", value: $0) }
        let headerIdentity = makeConversationIdentity(from: headers, myAliases: myAliases)

        let recipientIdentity = makeRecipientParticipantSetIdentity(
            recipients: recipients,
            myAliases: myAliases
        )

        XCTAssertEqual(recipientIdentity?.participantHash, headerIdentity.participantHash)
        XCTAssertEqual(recipientIdentity?.participants ?? [], headerIdentity.participants)
    }
}
