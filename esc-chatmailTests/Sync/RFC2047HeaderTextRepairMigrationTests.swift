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

    /// A failed save must not leave the decoded values staged: the cleanup
    /// hold (incremental) or the final save (full) saves the same context
    /// after this pass, and committing the repair there would leave the flag
    /// clear with no cache invalidation, so the re-run would find nothing to
    /// decode and never notify readers.
    func testRepair_saveFails_laterSaveOfSameContextCommitsNothing() async throws {
        // UUID-suffixed: the display-info notification and PersonCache are
        // process-global, so another suite must never post under this email.
        let email = "jose.\(UUID().uuidString.prefix(8).lowercased())@example.com"
        let encodedName = "=?utf-8?B?Sm9zw6k=?="
        let seedContext = stack.viewContext
        await seedContext.perform {
            _ = PersonBuilder()
                .withEmail(email)
                .withDisplayName(encodedName)
                .build(in: seedContext)
        }
        try stack.saveViewContext()

        let failingContext = FirstSaveFailingContext()
        failingContext.persistentStoreCoordinator = stack.persistentContainer.persistentStoreCoordinator
        failingContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        await runRepair(in: failingContext)
        // What settleCleanupSensitiveHold does next in runIncrementalCleanup
        // (and runFullCleanup's final save); this save really writes.
        let laterSaveSucceeded = await failingContext.performSaveIfNeeded(caller: "test")
        XCTAssertTrue(laterSaveSucceeded)

        // Revert-check: the context.rollback() on the save-failure path of
        // decodeRFC2047HeaderTextIfNeeded.
        let nameAfterLaterSave = try await storedDisplayName(forEmail: email)
        XCTAssertEqual(nameAfterLaterSave, encodedName, "The failed repair must not reach the store through a later save")
        XCTAssertFalse(migrationFlags.bool(forKey: DataCleanupService.rfc2047HeaderTextRepairKey))

        let posted = expectation(description: "the retry notifies readers of the decoded email")
        posted.assertForOverFulfill = false
        let observer = NotificationCenter.default.addObserver(
            forName: .personDisplayInfoDidChange,
            object: nil,
            queue: nil
        ) { notification in
            if PersonDisplayInfoChangeNotification.emails(from: notification).contains(email) {
                posted.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // The next cleanup runs on a fresh context.
        await runRepair()

        let retriedName = try await storedDisplayName(forEmail: email)
        XCTAssertEqual(retriedName, "José")
        XCTAssertTrue(migrationFlags.bool(forKey: DataCleanupService.rfc2047HeaderTextRepairKey))
        await fulfillment(of: [posted], timeout: 10)
    }

    // MARK: - Fixture Helpers

    private func runRepair(in migrationContext: NSManagedObjectContext? = nil) async {
        let service = DataCleanupService(
            coreDataStack: coreDataStack,
            conversationManager: ConversationManager(currentUserEmail: { "me@example.com" }),
            migrationFlags: migrationFlags,
            identityAliasProvider: { _ in ["me@example.com"] }
        )
        // A fresh background context per run mirrors the per-launch cleanup
        // entry point that invokes this migration.
        await service.decodeRFC2047HeaderTextIfNeeded(
            in: migrationContext ?? coreDataStack.newBackgroundContext()
        )
    }

    /// Reads through a fresh background context, so it sees only what reached
    /// the store.
    private func storedDisplayName(forEmail email: String) async throws -> String? {
        let readContext = coreDataStack.newBackgroundContext()
        return try await readContext.perform {
            let request = Person.fetchRequest()
            request.predicate = NSPredicate(format: "email == %@", email)
            let rows = try readContext.fetch(request)
            XCTAssertEqual(rows.count, 1, "Expected one Person row for the address")
            return try XCTUnwrap(rows.first).displayName
        }
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

/// Throws on its first `save()` and really saves on every later one.
/// `ScriptedSaveContext`'s fail-then-succeed mode never writes the store, so
/// it cannot show what a later save of the same context commits.
/// `@unchecked Sendable`: `lock` guards `saveAttempts`.
private final class FirstSaveFailingContext: NSManagedObjectContext, @unchecked Sendable {
    private let lock = NSLock()
    private var saveAttempts = 0

    init() {
        super.init(concurrencyType: .privateQueueConcurrencyType)
    }

    required init?(coder: NSCoder) {
        fatalError("not supported in tests")
    }

    override func save() throws {
        lock.lock()
        saveAttempts += 1
        let attempt = saveAttempts
        lock.unlock()

        if attempt == 1 {
            throw NSError(domain: NSCocoaErrorDomain, code: NSManagedObjectMergeError)
        }
        try super.save()
    }
}
