import XCTest
import CoreData
@testable import esc_chatmail

/// Covers `DataCleanupService.repairAddressShapedPersonDisplayNamesIfNeeded`,
/// the one-shot repair for `Person.displayName` rows that hold an email
/// address because a To/Cc header written as `"addr" <addr>` replaced the
/// stored name before `EmailNormalizer.isBetterDisplayName(_:than:forEmail:)`
/// refused to let it.
///
/// Fixtures are built inside `perform` on the private-queue
/// `stack.viewContext` and saved with `stack.saveViewContext()`; assertions
/// read through a fresh background context, and each repair run gets its own
/// background context, as the cleanup entry points do.
final class AddressShapedPersonNameRepairTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!
    private var migrationFlags: InMemoryMigrationFlagStore!
    /// UUID-suffixed addresses: the display-info notification and
    /// `PersonCache` are process-global, so another suite must never post or
    /// cache under the same email.
    private var jake: String!
    private var alice: String!

    private static let me = "me@example.com"

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        coreDataStack = CoreDataStack(persistentContainerForTesting: stack.persistentContainer)
        migrationFlags = InMemoryMigrationFlagStore()
        let suffix = UUID().uuidString.prefix(8).lowercased()
        jake = "jacob.laycock.\(suffix)@studs.com"
        alice = "alice.\(suffix)@example.com"
    }

    override func tearDown() {
        migrationFlags = nil
        coreDataStack = nil
        stack = nil
        jake = nil
        alice = nil
        super.tearDown()
    }

    // MARK: - Tests

    /// The reported case: Jake is only ever a To/Cc recipient, a newer Cc
    /// header used his address as his name, and his stored name became the
    /// address, so the group title counted him as unresolved ("Alice Smith +1").
    func testRepair_toOnlyParticipantWithRawHeaders_recoversNameAndRefreshesGroupTitle() async throws {
        let conversationID = try await seedGroupWithToOnlyJake(rawHeaders: true)

        await runRepair()

        // Revert-check: DataCleanupService.recipientHeaderDisplayNames(forEmail:in:)
        // (returning [] makes a To/Cc-only person recover nothing).
        let repairedName = try await storedDisplayName(forEmail: jake)
        XCTAssertEqual(repairedName, "Jake")

        // Revert-check: the conversationManager.updateConversationDisplayNames
        // call in repairAddressShapedPersonDisplayNamesIfNeeded (the title
        // keeps "Alice Smith +1" without it).
        let title = try await storedConversationTitle(conversationID)
        XCTAssertTrue(
            ["Alice & Jake", "Jake & Alice"].contains(title),
            "The group title must name the recovered participant, got \(title ?? "nil")"
        )
        XCTAssertTrue(migrationFlags.bool(forKey: DataCleanupService.addressShapedPersonNameRepairKey))
    }

    /// Pre-v6 rows: the To/Cc rows exist but their messages carry no raw
    /// recipient headers, so nothing names Jake. The From name on the same
    /// messages is Alice's, and must not be taken for his.
    ///
    /// HONEST SCOPE: this pins a non-change, so it also passes with the whole
    /// repair reverted. It fails if a fallback fills the gap (the message's
    /// senderName, or a name derived from the address).
    func testRepair_messagesWithoutRawHeaders_leavesRowUntouchedAndLatchesFlag() async throws {
        let conversationID = try await seedGroupWithToOnlyJake(rawHeaders: false)

        await runRepair()

        let name = try await storedDisplayName(forEmail: jake)
        XCTAssertEqual(name, jake, "With no stored header naming him, the row must keep what it had")
        let title = try await storedConversationTitle(conversationID)
        XCTAssertEqual(title, "Alice Smith +1")
        XCTAssertTrue(
            migrationFlags.bool(forKey: DataCleanupService.addressShapedPersonNameRepairKey),
            "An unrecoverable row must not keep the one-shot pass re-running"
        )
    }

    func testRepair_fromRow_recoversSenderName() async throws {
        let jake = self.jake!
        try await seed { context in
            let person = PersonBuilder().withEmail(jake).withDisplayName(jake).build(in: context)
            Self.addMessage(
                id: "from-jake",
                date: Date(timeIntervalSince1970: 1_000),
                senderEmail: jake,
                senderName: "Jacob Laycock",
                participants: [(person, .from)],
                in: context
            )
        }

        await runRepair()

        let name = try await storedDisplayName(forEmail: jake)
        XCTAssertEqual(name, "Jacob Laycock")
    }

    /// A refetch rewrites `senderEmail`/`senderName` but leaves the From
    /// participant row on the old person, whose name that header is not.
    func testRepair_fromRowWhoseMessageNowNamesAnotherSender_isIgnored() async throws {
        let jake = self.jake!
        let alice = self.alice!
        try await seed { context in
            let person = PersonBuilder().withEmail(jake).withDisplayName(jake).build(in: context)
            Self.addMessage(
                id: "refetched-sender",
                date: Date(timeIntervalSince1970: 2_000),
                senderEmail: alice,
                senderName: "Alice Smith",
                participants: [(person, .from)],
                in: context
            )
        }

        await runRepair()

        // Revert-check: the senderEmail guard in the `.from` case of
        // DataCleanupService.recoveredHeaderDisplayName(for:email:).
        let name = try await storedDisplayName(forEmail: jake)
        XCTAssertEqual(name, jake)
    }

    /// Two equally ranked names: the fold runs newest-first and replaces only
    /// on a strictly better name, so the newer one wins.
    func testRepair_equallyRankedHeaderNames_newestWins() async throws {
        let jake = self.jake!
        let alice = self.alice!
        try await seed { context in
            let person = PersonBuilder().withEmail(jake).withDisplayName(jake).build(in: context)
            let sender = PersonBuilder().withEmail(alice).withDisplayName("Alice Smith").build(in: context)
            Self.addMessage(
                id: "older",
                date: Date(timeIntervalSince1970: 1_000),
                senderEmail: alice,
                senderName: "Alice Smith",
                rawTo: "Jakey <\(jake)>",
                participants: [(sender, .from), (person, .to)],
                in: context
            )
            Self.addMessage(
                id: "newer",
                date: Date(timeIntervalSince1970: 2_000),
                senderEmail: alice,
                senderName: "Alice Smith",
                rawCc: "Jacob <\(jake)>",
                participants: [(sender, .from), (person, .cc)],
                in: context
            )
        }

        await runRepair()

        // Revert-check: the newest-first `candidates.sort` in
        // DataCleanupService.recoveredHeaderDisplayName(for:email:) (oldest-first
        // keeps "Jakey").
        let name = try await storedDisplayName(forEmail: jake)
        XCTAssertEqual(name, "Jacob")
    }

    /// "Jake @ Studs" contains "@" (so the predicate selects it) but embeds no
    /// address, so it is a name and the pass must not replace it, even with a
    /// header name that would outrank it.
    func testRepair_nameContainingAtSignButNoAddress_isLeftAlone() async throws {
        let jake = self.jake!
        let alice = self.alice!
        try await seed { context in
            let person = PersonBuilder().withEmail(jake).withDisplayName("Jake @ Studs").build(in: context)
            let sender = PersonBuilder().withEmail(alice).withDisplayName("Alice Smith").build(in: context)
            Self.addMessage(
                id: "longer-name",
                date: Date(timeIntervalSince1970: 1_000),
                senderEmail: alice,
                senderName: "Alice Smith",
                rawTo: "Jacob Tyler Laycock <\(jake)>",
                participants: [(sender, .from), (person, .to)],
                in: context
            )
        }

        await runRepair()

        // Revert-check: the isEmailAddressShapedDisplayName(storedName, forEmail:)
        // guard in repairAddressShapedPersonDisplayNamesIfNeeded.
        let name = try await storedDisplayName(forEmail: jake)
        XCTAssertEqual(name, "Jake @ Studs")
    }

    /// A dotless address (`priya@intranet`) is not matched by the bare-address
    /// pattern, but a `"priya@intranet" <priya@intranet>` header stored it as
    /// her name all the same, so the selection must recognize the person's own
    /// address too.
    func testRepair_storedNameIsOwnDotlessAddress_recoversName() async throws {
        let alice = self.alice!
        let priya = "priya.\(UUID().uuidString.prefix(8).lowercased())@intranet"
        try await seed { context in
            let person = PersonBuilder().withEmail(priya).withDisplayName(priya).build(in: context)
            let sender = PersonBuilder().withEmail(alice).withDisplayName("Alice Smith").build(in: context)
            Self.addMessage(
                id: "to-priya",
                date: Date(timeIntervalSince1970: 1_000),
                senderEmail: alice,
                senderName: "Alice Smith",
                rawTo: "Priya Shah <\(priya)>",
                participants: [(sender, .from), (person, .to)],
                in: context
            )
        }

        await runRepair()

        // Revert-check: the `forEmail:` argument of the storedName guard in
        // repairAddressShapedPersonDisplayNamesIfNeeded (the bare test skips
        // the row and it keeps the address).
        let name = try await storedDisplayName(forEmail: priya)
        XCTAssertEqual(name, "Priya Shah")
    }

    /// The only header naming her repeats her dotless address in other
    /// casing. That is still her address, not a name, so the row keeps what
    /// it had rather than trading one address for another.
    ///
    /// HONEST SCOPE: this also passes with the `forEmail:` argument of the
    /// recoveredName guard reverted, because `isBetterDisplayName` already
    /// refuses this variant over the stored address. It fails if both checks
    /// start accepting the address.
    func testRepair_onlyHeaderNameIsOwnDotlessAddress_isNotWritten() async throws {
        let alice = self.alice!
        let priya = "priya.\(UUID().uuidString.prefix(8).lowercased())@intranet"
        try await seed { context in
            let person = PersonBuilder().withEmail(priya).withDisplayName(priya).build(in: context)
            let sender = PersonBuilder().withEmail(alice).withDisplayName("Alice Smith").build(in: context)
            Self.addMessage(
                id: "to-priya-upper",
                date: Date(timeIntervalSince1970: 1_000),
                senderEmail: alice,
                senderName: "Alice Smith",
                rawTo: "\"\(priya.uppercased())\" <\(priya)>",
                participants: [(sender, .from), (person, .to)],
                in: context
            )
        }

        await runRepair()

        let name = try await storedDisplayName(forEmail: priya)
        XCTAssertEqual(name, priya)
        XCTAssertTrue(migrationFlags.bool(forKey: DataCleanupService.addressShapedPersonNameRepairKey))
    }

    /// Idempotency: with the flag cleared, a second run over the repaired
    /// store (one recovered row, one unrecoverable pre-v6 row) saves nothing.
    ///
    /// HONEST SCOPE: the no-op follows from the selection (a repaired row no
    /// longer holds an address) and from the unrecoverable row recovering
    /// nothing again; no single symbol's removal makes this test fail.
    func testRepair_secondRunWithClearedFlag_writesNothing() async throws {
        let jake = self.jake!
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let preV6 = "pre.v6.\(suffix)@studs.com"
        let bob = "bob.\(suffix)@example.com"
        let conversationID = try await seedGroupWithToOnlyJake(rawHeaders: true)
        try await seed { context in
            let person = PersonBuilder().withEmail(preV6).withDisplayName(preV6).build(in: context)
            let sender = PersonBuilder().withEmail(bob).withDisplayName("Bob Jones").build(in: context)
            Self.addMessage(
                id: "pre-v6",
                date: Date(timeIntervalSince1970: 500),
                senderEmail: bob,
                senderName: "Bob Jones",
                participants: [(sender, .from), (person, .to)],
                in: context
            )
        }

        await runRepair()
        let firstRunName = try await storedDisplayName(forEmail: jake)
        let firstRunTitle = try await storedConversationTitle(conversationID)
        XCTAssertEqual(firstRunName, "Jake")

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
        let secondRunName = try await storedDisplayName(forEmail: jake)
        let unrecoveredName = try await storedDisplayName(forEmail: preV6)
        let secondRunTitle = try await storedConversationTitle(conversationID)
        XCTAssertEqual(secondRunName, "Jake")
        XCTAssertEqual(unrecoveredName, preV6)
        XCTAssertEqual(secondRunTitle, firstRunTitle)
        XCTAssertTrue(rerunFlags.bool(forKey: DataCleanupService.addressShapedPersonNameRepairKey))
    }

    func testRepair_flagAlreadySet_doesNotRun() async throws {
        _ = try await seedGroupWithToOnlyJake(rawHeaders: true)
        migrationFlags.set(true, forKey: DataCleanupService.addressShapedPersonNameRepairKey)

        await runRepair()

        // Revert-check: the migrationFlags guard at the top of
        // repairAddressShapedPersonDisplayNamesIfNeeded.
        let name = try await storedDisplayName(forEmail: jake)
        XCTAssertEqual(name, jake)
    }

    func testRepair_saveFails_leavesFlagClear() async throws {
        _ = try await seedGroupWithToOnlyJake(rawHeaders: true)
        let failingContext = ScriptedSaveContext(
            error: NSError(domain: NSCocoaErrorDomain, code: NSManagedObjectMergeError)
        )
        failingContext.persistentStoreCoordinator = stack.persistentContainer.persistentStoreCoordinator
        failingContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        await runRepair(in: failingContext)

        // Revert-check: the performSaveIfNeeded guard ahead of the flag write
        // in repairAddressShapedPersonDisplayNamesIfNeeded.
        XCTAssertFalse(migrationFlags.bool(forKey: DataCleanupService.addressShapedPersonNameRepairKey))
        let name = try await storedDisplayName(forEmail: jake)
        XCTAssertEqual(name, jake)
    }

    /// A failed save must not leave the repair staged: the cleanup hold saves
    /// the same context right after this pass, and committing the repair
    /// there would leave the flag clear with no cache invalidation, so the
    /// re-run would find nothing to repair and never notify readers.
    func testRepair_saveFails_laterSaveOfSameContextCommitsNothing() async throws {
        _ = try await seedGroupWithToOnlyJake(rawHeaders: true)
        let jake = self.jake!
        let context = FirstSaveFailingContext()
        context.persistentStoreCoordinator = stack.persistentContainer.persistentStoreCoordinator
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy

        await runRepair(in: context)
        // What settleCleanupSensitiveHold does next in runIncrementalCleanup;
        // this save really writes.
        let laterSaveSucceeded = await context.performSaveIfNeeded(caller: "test")
        XCTAssertTrue(laterSaveSucceeded)

        // Revert-check: the context.rollback() on the save-failure path of
        // repairAddressShapedPersonDisplayNamesIfNeeded.
        let nameAfterLaterSave = try await storedDisplayName(forEmail: jake)
        XCTAssertEqual(nameAfterLaterSave, jake, "The failed repair must not reach the store through a later save")
        XCTAssertFalse(migrationFlags.bool(forKey: DataCleanupService.addressShapedPersonNameRepairKey))

        let posted = expectation(description: "the retry notifies readers of the repaired email")
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
        XCTAssertEqual(retriedName, "Jake")
        XCTAssertTrue(migrationFlags.bool(forKey: DataCleanupService.addressShapedPersonNameRepairKey))
        await fulfillment(of: [posted], timeout: 10)
    }

    func testRepair_postsDisplayInfoChangeForRepairedEmail() async throws {
        _ = try await seedGroupWithToOnlyJake(rawHeaders: true)
        let jake = self.jake!
        let posted = expectation(description: "display-info change names the repaired email")
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
        // repairAddressShapedPersonDisplayNamesIfNeeded.
        await fulfillment(of: [posted], timeout: 10)
    }

    /// The pass is wired into the flag-gated block of incremental cleanup,
    /// which is what runs it after a sync.
    func testRunIncrementalCleanup_runsRepair() async throws {
        _ = try await seedGroupWithToOnlyJake(rawHeaders: true)
        // Latch the other flag-gated migrations and keep the store-wide
        // maintenance off its cadence, so only this pass can write.
        migrationFlags.set(true, forKey: DataCleanupService.participantSetSplitMigrationKey)
        migrationFlags.set(true, forKey: DataCleanupService.rfc2047HeaderTextRepairKey)
        let scheduleSuiteName = "AddressShapedPersonNameRepairTests.\(UUID().uuidString)"
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

        // Revert-check: the repairAddressShapedPersonDisplayNamesIfNeeded call
        // in DataCleanupService.runIncrementalCleanup(in:).
        let name = try await storedDisplayName(forEmail: jake)
        XCTAssertEqual(name, "Jake")
        XCTAssertTrue(migrationFlags.bool(forKey: DataCleanupService.addressShapedPersonNameRepairKey))
    }

    // MARK: - Fixture Helpers

    /// Me, Alice (the sender) and Jake (To on the older message, Cc on the
    /// newer one) in one group. Jake's stored name is his address and the
    /// stored title counts him as unresolved. With `rawHeaders`, the older To
    /// header names him "Jake" and the newer Cc header uses his address as his
    /// name; without, both messages predate model v6.
    /// - Returns: The conversation's id.
    private func seedGroupWithToOnlyJake(rawHeaders: Bool) async throws -> UUID {
        let jake = self.jake!
        let alice = self.alice!
        let conversationID = UUID()
        try await seed { context in
            let me = PersonBuilder().withEmail(Self.me).withDisplayName("Me").build(in: context)
            let sender = PersonBuilder().withEmail(alice).withDisplayName("Alice Smith").build(in: context)
            let person = PersonBuilder().withEmail(jake).withDisplayName(jake).build(in: context)
            let conversation = ConversationBuilder()
                .withId(conversationID)
                .withParticipantHash("p|group-\(conversationID.uuidString)")
                .withDisplayName("Alice Smith +1")
                .withParticipant(me)
                .withParticipant(sender)
                .withParticipant(person)
                .build(in: context)
            Self.addMessage(
                id: "to-jake-\(conversationID.uuidString)",
                date: Date(timeIntervalSince1970: 1_000),
                senderEmail: alice,
                senderName: "Alice Smith",
                rawTo: rawHeaders ? "Me <\(Self.me)>, Jake <\(jake)>" : nil,
                participants: [(sender, .from), (me, .to), (person, .to)],
                conversation: conversation,
                in: context
            )
            Self.addMessage(
                id: "cc-jake-\(conversationID.uuidString)",
                date: Date(timeIntervalSince1970: 2_000),
                senderEmail: alice,
                senderName: "Alice Smith",
                rawTo: rawHeaders ? "Me <\(Self.me)>" : nil,
                rawCc: rawHeaders ? "\"\(jake)\" <\(jake)>" : nil,
                participants: [(sender, .from), (me, .to), (person, .cc)],
                conversation: conversation,
                in: context
            )
        }
        return conversationID
    }

    private func seed(_ build: @escaping (NSManagedObjectContext) -> Void) async throws {
        let context = stack.viewContext
        await context.perform { build(context) }
        try stack.saveViewContext()
    }

    /// Call on `context`'s queue.
    private static func addMessage(
        id: String,
        date: Date,
        senderEmail: String,
        senderName: String?,
        rawTo: String? = nil,
        rawCc: String? = nil,
        participants: [(person: Person, kind: ParticipantKind)],
        conversation: Conversation? = nil,
        in context: NSManagedObjectContext
    ) {
        let builder = MessageBuilder()
            .withId(id)
            .withDate(date)
            .withSender(email: senderEmail, name: senderName)
        if let conversation {
            _ = builder.inConversation(conversation)
        }
        let message = builder.build(in: context)
        message.rawToHeader = rawTo
        message.rawCcHeader = rawCc
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
        await service.repairAddressShapedPersonDisplayNamesIfNeeded(
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
