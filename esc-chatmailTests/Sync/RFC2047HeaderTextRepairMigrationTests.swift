import XCTest
import CoreData
@testable import esc_chatmail

/// Covers `DataCleanupService.decodeRFC2047HeaderTextIfNeeded`, the one-shot
/// repair that decodes raw RFC 2047 encoded-words persisted into display
/// fields by builds that predate ingestion-time decoding (issue #149).
final class RFC2047HeaderTextRepairMigrationTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!
    private var context: NSManagedObjectContext!
    private var migrationFlags: InMemoryMigrationFlagStore!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        coreDataStack = CoreDataStack(persistentContainerForTesting: stack.persistentContainer)
        context = stack.viewContext
        migrationFlags = InMemoryMigrationFlagStore()
    }

    override func tearDown() {
        migrationFlags = nil
        context = nil
        coreDataStack = nil
        stack = nil
        super.tearDown()
    }

    // MARK: - Tests

    func testDecodesGarbledPersonMessageAndConversationFields() async throws {
        PersonBuilder()
            .withEmail("jose@example.com")
            .withDisplayName("=?utf-8?B?Sm9zw6k=?=")
            .build(in: context)

        let conversation = ConversationBuilder()
            .withDisplayName("=?utf-8?Q?Costco_Wholesale?=")
            .withSnippet("Fwd: \"=?utf-8?B?SsO2cmcgTcO8bGxlcg==?=\"")
            .build(in: context)

        MessageBuilder()
            .withId("garbled-message")
            .withSender(email: "jose@example.com", name: "=?utf-8?q?Jos=C3=A9_Garc=C3=ADa?=")
            .withSubject("=?utf-8?B?SsO2cmcgTcO8bGxlcg==?= weekly")
            .inConversation(conversation)
            .build(in: context)
        try context.save()

        await runRepair()

        context.refreshAllObjects()
        let person = try fetchPerson("jose@example.com")
        XCTAssertEqual(person.displayName, "José")

        let message = try fetchMessage("garbled-message")
        XCTAssertEqual(message.senderName, "José García")
        XCTAssertEqual(message.subject, "Jörg Müller weekly")

        let repairedConversation = try XCTUnwrap(message.conversation)
        XCTAssertEqual(repairedConversation.displayName, "Costco Wholesale")
        XCTAssertEqual(repairedConversation.snippet, "Fwd: \"Jörg Müller\"")

        XCTAssertTrue(migrationFlags.bool(forKey: DataCleanupService.rfc2047HeaderTextRepairKey))
    }

    func testCleanAndLookalikeValuesStayUntouched() async throws {
        PersonBuilder()
            .withEmail("clean@example.com")
            .withDisplayName("Clean Name")
            .build(in: context)

        // Contains "=?" and "?=" but is not a well-formed encoded word (the
        // charset slot has whitespace), so it must survive verbatim.
        MessageBuilder()
            .withId("lookalike-message")
            .withSender(email: "clean@example.com", name: "Clean Name")
            .withSubject("price =? 100 ?= final")
            .build(in: context)
        try context.save()

        await runRepair()

        context.refreshAllObjects()
        XCTAssertEqual(try fetchPerson("clean@example.com").displayName, "Clean Name")
        let message = try fetchMessage("lookalike-message")
        XCTAssertEqual(message.senderName, "Clean Name")
        XCTAssertEqual(message.subject, "price =? 100 ?= final")
        XCTAssertTrue(migrationFlags.bool(forKey: DataCleanupService.rfc2047HeaderTextRepairKey))
    }

    func testEmptyDecodedDisplayNameBecomesNil() async throws {
        PersonBuilder()
            .withEmail("empty@example.com")
            .withDisplayName("=?utf-8?B??=")
            .build(in: context)
        try context.save()

        await runRepair()

        context.refreshAllObjects()
        XCTAssertNil(try fetchPerson("empty@example.com").displayName)
    }

    func testFlagPreventsReRun() async throws {
        migrationFlags.set(true, forKey: DataCleanupService.rfc2047HeaderTextRepairKey)

        PersonBuilder()
            .withEmail("jose@example.com")
            .withDisplayName("=?utf-8?B?Sm9zw6k=?=")
            .build(in: context)
        try context.save()

        await runRepair()

        context.refreshAllObjects()
        XCTAssertEqual(try fetchPerson("jose@example.com").displayName, "=?utf-8?B?Sm9zw6k=?=")
    }

    // MARK: - Fixture Helpers

    private func runRepair() async {
        let service = DataCleanupService(
            coreDataStack: coreDataStack,
            conversationManager: ConversationManager(currentUserEmail: { "me@example.com" }),
            migrationFlags: migrationFlags,
            identityAliasProvider: { _ in ["me@example.com"] }
        )
        // A fresh background context per run mirrors the per-launch cleanup
        // entry point that invokes this migration.
        let migrationContext = coreDataStack.newBackgroundContext()
        await service.decodeRFC2047HeaderTextIfNeeded(in: migrationContext)
    }

    private func fetchPerson(_ email: String) throws -> Person {
        let request = Person.fetchRequest()
        request.predicate = NSPredicate(format: "email == %@", email)
        request.fetchLimit = 1
        return try XCTUnwrap(context.fetch(request).first)
    }

    private func fetchMessage(_ id: String) throws -> Message {
        let request = Message.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id)
        request.fetchLimit = 1
        return try XCTUnwrap(context.fetch(request).first)
    }
}
