import XCTest
import CoreData
import SQLite3
@testable import esc_chatmail

/// Pins the store the scale harness measures on, at a size the default plan
/// can afford (`ScaleStoreShape.miniature`, 2,000 messages). The harness's
/// own suites run only under `--performance`; a seeder that drifted from the
/// shape it claims would make every one of their numbers mean something else,
/// and nothing in an ordinary run would say so.
final class ScaleStoreSeederTests: XCTestCase {
    private static let shape = ScaleStoreShape.miniature

    // MARK: - The plan

    /// Revert-check: seeding the shuffle in `ScaleStorePlan.init` from
    /// anything that changes between runs (a clock, `SystemRandomNumberGenerator`)
    /// makes the two plans disagree.
    func testPlan_sameShape_isTheSameMailbox() {
        let first = ScaleStorePlan(shape: Self.shape)
        let second = ScaleStorePlan(shape: Self.shape)

        XCTAssertEqual(first.conversationMessageCounts, second.conversationMessageCounts)
        for index in stride(from: 0, to: Self.shape.messageCount, by: 37) {
            XCTAssertEqual(first.facts(forMessage: index), second.facts(forMessage: index))
        }
    }

    /// Every message is in one conversation, each conversation has the count
    /// the plan gives it, its messages are numbered oldest first with no gap,
    /// and dates only go forward.
    ///
    /// Revert-check: removing the shuffle's `swapAt` in `ScaleStorePlan.init`
    /// leaves the messages of a conversation side by side (the last
    /// assertion).
    func testPlan_messagesAreSpreadOverConversationsInDateOrder() {
        let plan = ScaleStorePlan(shape: Self.shape)
        var nextOrdinal = [Int](repeating: 0, count: Self.shape.conversationCount)
        var previousDate = Date.distantPast
        var conversationChanges = 0
        var previousConversation = -1

        for index in 0..<Self.shape.messageCount {
            let facts = plan.facts(forMessage: index)
            XCTAssertEqual(facts.ordinalInConversation, nextOrdinal[facts.conversationIndex])
            nextOrdinal[facts.conversationIndex] += 1
            XCTAssertGreaterThan(facts.date, previousDate)
            previousDate = facts.date
            if facts.conversationIndex != previousConversation { conversationChanges += 1 }
            previousConversation = facts.conversationIndex
        }

        XCTAssertEqual(nextOrdinal, plan.conversationMessageCounts)
        XCTAssertEqual(plan.conversationMessageCounts.reduce(0, +), Self.shape.messageCount)
        XCTAssertEqual(plan.conversationMessageCounts.first, Self.shape.largestConversationMessageCount)
        XCTAssertEqual(previousDate, ScaleStorePlan.referenceDate)
        // Stored side by side, the conversation would change 200 times.
        XCTAssertGreaterThan(conversationChanges, Self.shape.messageCount / 2)
    }

    /// The proportions every hub-fault and unread-snapshot number scales
    /// with, within three points of what the shape asks for.
    ///
    /// Revert-check: in `ScaleStorePlan.facts(forMessage:)`, comparing the
    /// unread roll with `shape.unreadPerMille` itself (unread then means "of
    /// inbox mail", 18% of the store), or the inbox roll with
    /// `shape.inboxPerMille` (75%).
    func testPlan_proportionsAreTheShapes() {
        let plan = ScaleStorePlan(shape: Self.shape)
        let all = (0..<Self.shape.messageCount).map(plan.facts(forMessage:))
        func perMille(_ count: Int) -> Int { count * 1_000 / all.count }

        XCTAssertEqual(perMille(all.filter(\.isInInbox).count), Self.shape.inboxPerMille, accuracy: 30)
        XCTAssertEqual(perMille(all.filter(\.isUnread).count), Self.shape.unreadPerMille, accuracy: 30)
        XCTAssertEqual(perMille(all.filter(\.isFromMe).count), Self.shape.sentPerMille, accuracy: 30)
        XCTAssertEqual(
            Double(all.map(\.participantCount).reduce(0, +)) / Double(all.count), 2.6, accuracy: 0.1
        )
        XCTAssertEqual(
            Double(all.map(\.labelIDs.count).reduce(0, +)) / Double(all.count), 2.3, accuracy: 0.15
        )
        XCTAssertTrue(all.allSatisfy { !$0.isUnread || $0.isInInbox })
        XCTAssertTrue(all.allSatisfy { !$0.isFromMe || !$0.isInInbox })
    }

    // MARK: - The store

    private func count(
        _ entityName: String,
        _ predicate: NSPredicate? = nil,
        in context: NSManagedObjectContext
    ) throws -> Int {
        try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
            request.predicate = predicate
            return try context.count(for: request)
        }
    }

    /// The store holds what the manifest says, counted in the store, and the
    /// two hubs are hubs: INBOX is on the inbox messages and the user's own
    /// Person is on every message.
    ///
    /// Revert-check: in `ScaleStoreSeeder.insertMessages`, giving the
    /// recipient participant the counterpart's person on received mail (the
    /// user's participations drop to the sent mail), or leaving `labels`
    /// unset (INBOX has no members).
    func testSeed_storeHoldsWhatTheManifestSays() throws {
        let stack = TestCoreDataStack(storeKind: .sqlite)
        let manifest = try ScaleStoreSeeder.seed(Self.shape, in: stack.newBackgroundContext())
        let context = stack.viewContext

        XCTAssertEqual(try count("Message", in: context), Self.shape.messageCount)
        XCTAssertEqual(try count("Conversation", in: context), Self.shape.conversationCount)
        XCTAssertEqual(try count("Person", in: context), Self.shape.personCount)
        XCTAssertEqual(try count("Account", in: context), 1)
        XCTAssertEqual(try count("MessageParticipant", in: context), manifest.messageParticipantCount)
        XCTAssertEqual(
            try count("Message", MessagePredicates.inbox, in: context), manifest.inboxMessageCount
        )
        XCTAssertEqual(
            try count("Message", MessagePredicates.unread, in: context), manifest.unreadMessageCount
        )
        XCTAssertEqual(
            try count(
                "MessageParticipant",
                NSPredicate(format: "person.email == %@", manifest.selfEmail),
                in: context
            ),
            Self.shape.messageCount
        )
        XCTAssertEqual(
            try count(
                "Message",
                NSPredicate(format: "conversation.id == %@", manifest.largestConversationID as CVarArg),
                in: context
            ),
            manifest.largestConversationMessageCount
        )
        XCTAssertEqual(manifest.largestConversationMessageCount, Self.shape.largestConversationMessageCount)

        let memberships: Int = try context.performAndWait {
            let labels = try context.fetch(NSFetchRequest<Label>(entityName: "Label"))
            return labels.reduce(0) { $0 + ($1.messages?.count ?? 0) }
        }
        XCTAssertEqual(memberships, manifest.labelMembershipCount)
    }

    /// Each conversation's own row agrees with its messages, which is what
    /// the list's fetch sorts and filters on: an archived conversation has no
    /// INBOX mail, and one in the inbox carries its newest date and its
    /// unread count.
    ///
    /// Revert-check: skipping `writeRollups` leaves every conversation
    /// unarchived with no date; writing `archivedAt` for every conversation
    /// empties the list.
    func testSeed_conversationRowsAgreeWithTheirMessages() throws {
        let stack = TestCoreDataStack(storeKind: .sqlite)
        let manifest = try ScaleStoreSeeder.seed(Self.shape, in: stack.newBackgroundContext())
        let context = stack.viewContext

        XCTAssertEqual(
            try count("Conversation", NSPredicate(format: "archivedAt != nil"), in: context),
            manifest.archivedConversationCount
        )
        XCTAssertGreaterThan(manifest.archivedConversationCount, 0)
        XCTAssertLessThan(manifest.archivedConversationCount, Self.shape.conversationCount / 2)
        XCTAssertEqual(
            try count("Conversation", NSPredicate(format: "lastMessageDate == nil"), in: context), 0
        )
        XCTAssertEqual(
            try count(
                "Conversation",
                NSPredicate(
                    format: "archivedAt != nil AND SUBQUERY(messages, $m, ANY $m.labels.id == %@).@count > 0",
                    "INBOX"
                ),
                in: context
            ),
            0
        )

        try context.performAndWait {
            let request = NSFetchRequest<Conversation>(entityName: "Conversation")
            request.predicate = NSPredicate(format: "id == %@", manifest.ordinaryConversationID as CVarArg)
            let conversation = try XCTUnwrap(try context.fetch(request).first)
            let messages = conversation.messages ?? []

            XCTAssertNil(conversation.archivedAt)
            XCTAssertTrue(conversation.hasInbox)
            XCTAssertEqual(messages.count, manifest.ordinaryConversationMessageCount)
            XCTAssertEqual(Int(conversation.inboxUnreadCount), manifest.ordinaryConversationUnreadCount)
            XCTAssertEqual(messages.filter(\.isUnread).count, manifest.ordinaryConversationUnreadCount)
            XCTAssertEqual(conversation.lastMessageDate, messages.map(\.internalDate).max())
            XCTAssertGreaterThanOrEqual(conversation.participants?.count ?? 0, 2)
            let inboxMessage = try XCTUnwrap(
                messages.first { $0.id == manifest.ordinaryConversationInboxMessageID }
            )
            XCTAssertTrue((inboxMessage.labels ?? []).contains { $0.id == "INBOX" })
        }
    }

    // MARK: - The template

    /// Each test gets its own copy: what one does to its store, the next one
    /// does not see, and the store is seeded once.
    ///
    /// Revert-check: `ScaleStoreTemplate.makeStack` opening the template's
    /// own file (the deletion shows in the second stack), or `seededStore`
    /// not keeping its result (the two manifests still agree, so that one is
    /// caught only by the time a second seeding takes; the copy is what this
    /// pins).
    func testTemplate_stacksAreCopies_notOneSharedStore() throws {
        let template = ScaleStoreTemplate(shape: Self.shape)
        let first = try template.makeStack()
        let second = try template.makeStack()
        XCTAssertEqual(first.manifest, second.manifest)

        let firstContext = first.stack.viewContext
        try firstContext.performAndWait {
            let request = NSFetchRequest<Message>(entityName: "Message")
            request.predicate = MessagePredicates.id(first.manifest.ordinaryConversationInboxMessageID)
            firstContext.delete(try XCTUnwrap(try firstContext.fetch(request).first))
            try firstContext.save()
        }

        XCTAssertEqual(try count("Message", in: firstContext), Self.shape.messageCount - 1)
        XCTAssertEqual(try count("Message", in: second.stack.viewContext), Self.shape.messageCount)
        XCTAssertEqual(try count("Message", in: try template.makeStack().stack.viewContext), Self.shape.messageCount)
    }

    /// The one number in the first row of what `sql` returns.
    private func scalar(_ sql: String, in database: OpaquePointer?) throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "\(sql): \(String(cString: sqlite3_errmsg(database)))"
            ])
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// How many rows of statistics SQLite holds for the store (`sqlite_stat1`,
    /// which `ANALYZE` writes), or nil for a store with no such table. Read
    /// on a connection of the test's own, because the table is SQLite's and
    /// Core Data has no name for it.
    private func statisticsRowCount(of stack: TestCoreDataStack) throws -> Int? {
        let storeURL = try XCTUnwrap(
            stack.persistentContainer.persistentStoreCoordinator.persistentStores.first?.url
        )
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: storeURL.path])
        }
        let tableCount = try scalar(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'sqlite_stat1'", in: database
        )
        guard tableCount == 1 else { return nil }
        return try scalar("SELECT COUNT(*) FROM sqlite_stat1", in: database)
    }

    /// `.analyzed` gives the copy SQLite's statistics, and `.none` leaves it
    /// without the table, which is the state a new install is in.
    ///
    /// What is asked is whether the statistics are there, not which plan
    /// SQLite then picks. On a store this small that choice is the planner's
    /// cost estimate, which another SQLite can make the other way, and this
    /// suite runs in the default plan on whatever runtime CI has. What the
    /// statistics do to a plan is `ScaleQueryPlanTests`' to say, at S2 size.
    ///
    /// Revert-check: the `ANALYZE` in `ScaleStoreTemplate.makeStack` (the
    /// analyzed copy then has no table either).
    func testTemplate_analyzedCopyHasStatistics_plainCopyHasNone() throws {
        let template = ScaleStoreTemplate(shape: Self.shape)

        let plain = try template.makeStack(statistics: .none).stack
        XCTAssertNil(try statisticsRowCount(of: plain))

        let analyzed = try template.makeStack(statistics: .analyzed).stack
        XCTAssertGreaterThan(try XCTUnwrap(try statisticsRowCount(of: analyzed)), 0)
        // The copy still opens as the seeded store.
        XCTAssertEqual(try count("Message", in: analyzed.viewContext), Self.shape.messageCount)
    }
}
