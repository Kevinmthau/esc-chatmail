import XCTest
import CoreData
@testable import esc_chatmail

/// Covers `DataCleanupService.peelQuoteWrappedDisplayNamesIfNeeded`, the
/// one-shot repair for `Person.displayName` and `Message.senderName` values
/// stored with Outlook's wrapping quotes (`'Jake Laycock'`) before
/// `EmailNormalizer.sanitizeDisplayName` peeled them, and for the stored
/// titles derived from them.
///
/// Fixtures are built inside `perform` on the private-queue
/// `stack.viewContext` and saved with `stack.saveViewContext()`; assertions
/// read through a fresh background context, and each repair run gets its own
/// background context, as the cleanup entry points do.
final class QuoteWrappedDisplayNameRepairTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!
    private var migrationFlags: InMemoryMigrationFlagStore!
    /// UUID-suffixed addresses: the display-info notification and
    /// `PersonCache` are process-global, so another suite must never post or
    /// cache under the same email. The suffix also keeps every fixture name
    /// from restating its address.
    private var suffix: String!
    private var jake: String!
    private var alice: String!

    private static let me = "me@example.com"

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        coreDataStack = CoreDataStack(persistentContainerForTesting: stack.persistentContainer)
        migrationFlags = InMemoryMigrationFlagStore()
        suffix = String(UUID().uuidString.prefix(8).lowercased())
        jake = "jake.\(suffix!)@studs.com"
        alice = "alice.\(suffix!)@example.com"
    }

    override func tearDown() {
        migrationFlags = nil
        coreDataStack = nil
        stack = nil
        suffix = nil
        jake = nil
        alice = nil
        super.tearDown()
    }

    // MARK: - Tests

    /// The reported case: Jake is only ever a recipient and his stored name
    /// kept Outlook's quotes, Alice's From header did too, and the group title
    /// derived from them spells both out.
    func testRepair_quoteWrappedPersonAndSenderNames_peelsRowsAndRefreshesGroupTitle() async throws {
        let conversationID = try await seedGroupWithQuotedNames()

        await runRepair()

        // Revert-check: the `person.displayName` write in
        // DataCleanupService.peelQuoteWrappedDisplayNamesIfNeeded.
        let jakeName = try await storedDisplayName(forEmail: jake)
        XCTAssertEqual(jakeName, "Jake Laycock")
        // Revert-check: the `message.senderName` write in
        // DataCleanupService.peelQuoteWrappedDisplayNamesIfNeeded.
        let senderName = try await storedSenderName(forMessage: messageID(conversationID))
        XCTAssertEqual(senderName, "Alice Smith")
        // Revert-check: the conversationManager.updateConversationDisplayNames
        // call in peelQuoteWrappedDisplayNamesIfNeeded (the title keeps its
        // quotes without it).
        let title = try await storedConversationTitle(conversationID)
        XCTAssertTrue(
            ["Alice & Jake", "Jake & Alice"].contains(title),
            "The group title must name both participants without quotes, got \(title ?? "nil")"
        )
        XCTAssertTrue(migrationFlags.bool(forKey: DataCleanupService.quoteWrappedDisplayNameRepairKey))
    }

    /// Only the From header was quoted; the Person row is clean, so the title
    /// to refresh is found through the message.
    ///
    /// Revert-check: removing the `conversationIDs.insert` in the message loop
    /// of `DataCleanupService.peelQuoteWrappedDisplayNamesIfNeeded` fails this
    /// test (the title keeps the quoted name).
    func testRepair_quoteWrappedSenderNameOnly_refreshesItsConversationTitle() async throws {
        let jake = self.jake!
        let conversationID = UUID()
        try await seed { context in
            let me = PersonBuilder().withEmail(Self.me).withDisplayName("Me").build(in: context)
            let sender = PersonBuilder().withEmail(jake).withDisplayName("Jake Laycock").build(in: context)
            let conversation = ConversationBuilder()
                .withId(conversationID)
                .withParticipantHash("p|one-\(conversationID.uuidString)")
                .withDisplayName("'Jake Laycock'")
                .withParticipant(me)
                .withParticipant(sender)
                .build(in: context)
            Self.addMessage(
                id: "from-jake-\(conversationID.uuidString)",
                senderEmail: jake,
                senderName: "'Jake Laycock'",
                participants: [(sender, .from), (me, .to)],
                conversation: conversation,
                in: context
            )
        }

        await runRepair()

        let senderName = try await storedSenderName(forMessage: "from-jake-\(conversationID.uuidString)")
        XCTAssertEqual(senderName, "Jake Laycock")
        let title = try await storedConversationTitle(conversationID)
        XCTAssertEqual(title, "Jake Laycock")
    }

    /// Every quote pair the peel recognizes, and every layer of it, is
    /// selected; a name that is only quotes becomes no name.
    ///
    /// Revert-check: selecting rows by the ASCII single quote alone instead of
    /// `EmailNormalizer.wrappingQuoteOpeners` in
    /// `DataCleanupService.peelQuoteWrappedDisplayNamesIfNeeded` fails this
    /// test (the typographic rows keep their quotes).
    func testRepair_typographicAndNestedQuotes_arePeeled() async throws {
        let suffix = self.suffix!
        let stored: [(email: String, name: String, expected: String?)] = [
            ("bob.\(suffix)@example.com", "\u{2018}Bob Jones\u{2019}", "Bob Jones"),
            ("kim.\(suffix)@example.com", "\u{201C}Kim Lee\u{201D}", "Kim Lee"),
            ("zoe.\(suffix)@example.fr", "\u{00AB}Zo\u{00E9} Roux\u{00BB}", "Zo\u{00E9} Roux"),
            ("ana.\(suffix)@example.com", "''Ana Ruiz''", "Ana Ruiz"),
            ("nobody.\(suffix)@example.com", "''", nil)
        ]
        try await seed { context in
            for row in stored {
                _ = PersonBuilder().withEmail(row.email).withDisplayName(row.name).build(in: context)
            }
        }

        await runRepair()

        for row in stored {
            let name = try await storedDisplayName(forEmail: row.email)
            XCTAssertEqual(name, row.expected, row.name)
        }
    }

    /// HONEST SCOPE: pins a non-change, so it also passes with the whole repair
    /// reverted. It fails if the selection or the peel over-matches: a quote
    /// inside a name, or one that does not wrap the whole name (Google Groups'
    /// relay form), is part of the name, and such rows are neither rewritten
    /// nor saved.
    func testRepair_quoteNotWrappingWholeName_isLeftUntouched() async throws {
        let suffix = self.suffix!
        let band = "band.\(suffix)@example.com"
        let patrick = "pobrien.\(suffix)@example.com"
        let group = "studs-team.\(suffix)@googlegroups.com"
        try await seed { context in
            _ = PersonBuilder().withEmail(band).withDisplayName("'Til Tuesday").build(in: context)
            _ = PersonBuilder().withEmail(patrick).withDisplayName("Patrick O'Brien").build(in: context)
            let relay = PersonBuilder().withEmail(group).withDisplayName("Studs Team").build(in: context)
            Self.addMessage(
                id: "relay-\(suffix)",
                senderEmail: group,
                senderName: "'Jacob Laycock' via Studs Team",
                participants: [(relay, .from)],
                in: context
            )
        }

        let context = coreDataStack.newBackgroundContext()
        let saves = SaveCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: context,
            queue: nil
        ) { _ in
            saves.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await runRepair(in: context)

        XCTAssertEqual(saves.count, 0, "Nothing wrapped, so nothing to save")
        let bandName = try await storedDisplayName(forEmail: band)
        let patrickName = try await storedDisplayName(forEmail: patrick)
        let relayName = try await storedSenderName(forMessage: "relay-\(suffix)")
        XCTAssertEqual(bandName, "'Til Tuesday")
        XCTAssertEqual(patrickName, "Patrick O'Brien")
        XCTAssertEqual(relayName, "'Jacob Laycock' via Studs Team")
        XCTAssertTrue(migrationFlags.bool(forKey: DataCleanupService.quoteWrappedDisplayNameRepairKey))
    }

    /// Idempotency: with the flag cleared, a second run over the repaired
    /// store saves nothing.
    ///
    /// HONEST SCOPE: the no-op follows from the selection (a peeled row no
    /// longer starts with a quote); no single symbol's removal makes this test
    /// fail.
    func testRepair_secondRunWithClearedFlag_writesNothing() async throws {
        let conversationID = try await seedGroupWithQuotedNames()
        await runRepair()
        let firstRunTitle = try await storedConversationTitle(conversationID)

        let rerunFlags = InMemoryMigrationFlagStore()
        let rerunContext = coreDataStack.newBackgroundContext()
        let saves = SaveCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: rerunContext,
            queue: nil
        ) { _ in
            saves.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await runRepair(flags: rerunFlags, in: rerunContext)

        XCTAssertEqual(saves.count, 0, "A second run over a repaired store must not save")
        let hasChanges = await rerunContext.perform { rerunContext.hasChanges }
        XCTAssertFalse(hasChanges)
        let secondRunTitle = try await storedConversationTitle(conversationID)
        XCTAssertEqual(secondRunTitle, firstRunTitle)
        XCTAssertTrue(rerunFlags.bool(forKey: DataCleanupService.quoteWrappedDisplayNameRepairKey))
    }

    func testRepair_flagAlreadySet_doesNotRun() async throws {
        _ = try await seedGroupWithQuotedNames()
        migrationFlags.set(true, forKey: DataCleanupService.quoteWrappedDisplayNameRepairKey)

        await runRepair()

        // Revert-check: the migrationFlags guard at the top of
        // peelQuoteWrappedDisplayNamesIfNeeded.
        let name = try await storedDisplayName(forEmail: jake)
        XCTAssertEqual(name, "'Jake Laycock'")
    }

    /// A failed save must leave the flag clear and the repair unstaged: the
    /// cleanup hold saves the same context right after this pass, and
    /// committing the repair there would leave the flag clear with no cache
    /// invalidation, so the re-run would find nothing to peel and never
    /// notify readers.
    func testRepair_saveFails_leavesFlagClearAndLaterSaveOfSameContextCommitsNothing() async throws {
        _ = try await seedGroupWithQuotedNames()
        let jake = self.jake!
        let context = FirstSaveFailingContext()
        context.persistentStoreCoordinator = stack.persistentContainer.persistentStoreCoordinator
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        await runRepair(in: context)
        // Revert-check: the performSaveIfNeeded guard ahead of the flag write
        // in peelQuoteWrappedDisplayNamesIfNeeded.
        XCTAssertFalse(migrationFlags.bool(forKey: DataCleanupService.quoteWrappedDisplayNameRepairKey))
        // What settleCleanupSensitiveHold does next in runIncrementalCleanup;
        // this save really writes.
        let laterSaveSucceeded = await context.performSaveIfNeeded(caller: "test")
        XCTAssertTrue(laterSaveSucceeded)

        // Revert-check: the context.rollback() on the save-failure path of
        // peelQuoteWrappedDisplayNamesIfNeeded.
        let nameAfterLaterSave = try await storedDisplayName(forEmail: jake)
        XCTAssertEqual(nameAfterLaterSave, "'Jake Laycock'", "The failed repair must not reach the store through a later save")

        let posted = expectation(description: "the retry notifies readers of the peeled email")
        posted.assertForOverFulfill = false
        let observer = NotificationCenter.default.addObserver(
            forName: .personDisplayInfoDidChange,
            object: nil,
            queue: nil
        ) { notification in
            if PersonDisplayInfoChangeNotification.emails(from: notification).contains(jake) {
                posted.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // The next cleanup runs on a fresh context.
        await runRepair()

        let retriedName = try await storedDisplayName(forEmail: jake)
        XCTAssertEqual(retriedName, "Jake Laycock")
        XCTAssertTrue(migrationFlags.bool(forKey: DataCleanupService.quoteWrappedDisplayNameRepairKey))
        await fulfillment(of: [posted], timeout: 10)
    }

    func testRepair_postsDisplayInfoChangeForPeeledEmail() async throws {
        _ = try await seedGroupWithQuotedNames()
        let jake = self.jake!
        let posted = expectation(description: "display-info change names the peeled email")
        posted.assertForOverFulfill = false
        let observer = NotificationCenter.default.addObserver(
            forName: .personDisplayInfoDidChange,
            object: nil,
            queue: nil
        ) { notification in
            if PersonDisplayInfoChangeNotification.emails(from: notification).contains(jake) {
                posted.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await runRepair()

        // Revert-check: the invalidatePersonCacheAndPostLater call in
        // peelQuoteWrappedDisplayNamesIfNeeded.
        await fulfillment(of: [posted], timeout: 10)
    }

    /// The pass is wired into the flag-gated block of incremental cleanup,
    /// which is what runs it after a sync.
    func testRunIncrementalCleanup_runsRepair() async throws {
        _ = try await seedGroupWithQuotedNames()
        // Latch the other flag-gated migrations and keep the store-wide
        // maintenance off its cadence, so only this pass can write.
        migrationFlags.set(true, forKey: DataCleanupService.participantSetSplitMigrationKey)
        migrationFlags.set(true, forKey: DataCleanupService.rfc2047HeaderTextRepairKey)
        migrationFlags.set(true, forKey: DataCleanupService.addressShapedPersonNameRepairKey)
        let scheduleSuiteName = "QuoteWrappedDisplayNameRepairTests.\(UUID().uuidString)"
        let scheduleDefaults = try XCTUnwrap(UserDefaults(suiteName: scheduleSuiteName))
        defer { scheduleDefaults.removePersistentDomain(forName: scheduleSuiteName) }
        DataCleanupService.IncrementalCleanupSchedule.markRun(defaults: scheduleDefaults)

        let service = DataCleanupService(
            coreDataStack: coreDataStack,
            conversationManager: ConversationManager(currentUserEmail: { Self.me }),
            migrationFlags: migrationFlags,
            identityAliasProvider: { _ in [Self.me] },
            maintenanceScheduleDefaults: scheduleDefaults
        )
        await service.runIncrementalCleanup(in: coreDataStack.newBackgroundContext())

        // Revert-check: the peelQuoteWrappedDisplayNamesIfNeeded call in
        // DataCleanupService.runIncrementalCleanup(in:).
        let name = try await storedDisplayName(forEmail: jake)
        XCTAssertEqual(name, "Jake Laycock")
        XCTAssertTrue(migrationFlags.bool(forKey: DataCleanupService.quoteWrappedDisplayNameRepairKey))
    }

    // MARK: - Fixture Helpers

    /// Me, Alice (the sender) and Jake (a To recipient) in one group. Jake's
    /// stored name and Alice's From header name kept Outlook's quotes, and the
    /// stored title was derived from them.
    /// - Returns: The conversation's id.
    private func seedGroupWithQuotedNames() async throws -> UUID {
        let jake = self.jake!
        let alice = self.alice!
        let conversationID = UUID()
        let messageID = messageID(conversationID)
        try await seed { context in
            let me = PersonBuilder().withEmail(Self.me).withDisplayName("Me").build(in: context)
            let sender = PersonBuilder().withEmail(alice).withDisplayName("Alice Smith").build(in: context)
            let person = PersonBuilder().withEmail(jake).withDisplayName("'Jake Laycock'").build(in: context)
            let conversation = ConversationBuilder()
                .withId(conversationID)
                .withParticipantHash("p|group-\(conversationID.uuidString)")
                .withDisplayName("'Alice & 'Jake")
                .withParticipant(me)
                .withParticipant(sender)
                .withParticipant(person)
                .build(in: context)
            Self.addMessage(
                id: messageID,
                senderEmail: alice,
                senderName: "'Alice Smith'",
                participants: [(sender, .from), (me, .to), (person, .to)],
                conversation: conversation,
                in: context
            )
        }
        return conversationID
    }

    private func messageID(_ conversationID: UUID) -> String {
        "to-jake-\(conversationID.uuidString)"
    }

    private func seed(_ build: @escaping (NSManagedObjectContext) -> Void) async throws {
        let context = stack.viewContext
        await context.perform { build(context) }
        try stack.saveViewContext()
    }

    /// Call on `context`'s queue.
    private static func addMessage(
        id: String,
        senderEmail: String,
        senderName: String?,
        participants: [(person: Person, kind: ParticipantKind)],
        conversation: Conversation? = nil,
        in context: NSManagedObjectContext
    ) {
        let builder = MessageBuilder()
            .withId(id)
            .withDate(Date(timeIntervalSince1970: 1_000))
            .withSender(email: senderEmail, name: senderName)
        if let conversation {
            _ = builder.inConversation(conversation)
        }
        let message = builder.build(in: context)
        for entry in participants {
            let participant = context.insertTestObject(MessageParticipant.self)
            participant.id = UUID()
            participant.participantKind = entry.kind
            participant.person = entry.person
            participant.message = message
        }
    }

    private func runRepair(
        flags: InMemoryMigrationFlagStore? = nil,
        in context: NSManagedObjectContext? = nil
    ) async {
        let service = DataCleanupService(
            coreDataStack: coreDataStack,
            conversationManager: ConversationManager(currentUserEmail: { Self.me }),
            migrationFlags: flags ?? migrationFlags,
            identityAliasProvider: { _ in [Self.me] }
        )
        await service.peelQuoteWrappedDisplayNamesIfNeeded(
            in: context ?? coreDataStack.newBackgroundContext()
        )
    }

    private func storedDisplayName(forEmail email: String) async throws -> String? {
        let context = coreDataStack.newBackgroundContext()
        return try await context.perform {
            let request = Person.fetchRequest()
            request.predicate = NSPredicate(format: "email == %@", email)
            let rows = try context.fetch(request)
            XCTAssertEqual(rows.count, 1, "Expected one Person row for the address")
            return try XCTUnwrap(rows.first).displayName
        }
    }

    private func storedSenderName(forMessage id: String) async throws -> String? {
        let context = coreDataStack.newBackgroundContext()
        return try await context.perform {
            let request = Message.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id)
            request.fetchLimit = 1
            return try XCTUnwrap(context.fetch(request).first).senderName
        }
    }

    private func storedConversationTitle(_ id: UUID) async throws -> String? {
        let context = coreDataStack.newBackgroundContext()
        return try await context.perform {
            let request = Conversation.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            request.fetchLimit = 1
            return try XCTUnwrap(context.fetch(request).first).displayName
        }
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

/// Counts `NSManagedObjectContextDidSave` posts, which arrive synchronously on
/// the saving context's queue while the test task awaits the run.
/// `@unchecked Sendable`: `lock` guards `value`.
private final class SaveCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
