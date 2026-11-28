import XCTest
import CoreData
@testable import esc_chatmail

/// `ConversationRollupBoundedReader` must give what a walk of the messages
/// gives (`ConversationRollupSnapshot.make(from:)`, `ConversationSenderSummary.walking`),
/// with the context's unsaved changes, because rollups run before the run's
/// save (architecture review 2026-11, data-model#4). The store is SQLite: the
/// reader's grouped fetches are SQLite's, and the in-memory store keeps the
/// walk (`supportsBoundedReads`).
///
/// Each test stores a conversation, changes it in a second context without
/// saving, and compares the reader with a walk in that context. The walk runs
/// second, so the reader reads a context that has not had the messages
/// faulted in.
final class ConversationRollupBoundedReaderTests: XCTestCase {
    private var stack: TestCoreDataStack!

    private static let base = Date(timeIntervalSince1970: 1_700_000_000)
    private static let me = "me@example.com"

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack(storeKind: .sqlite)
    }

    override func tearDown() {
        stack = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private struct Row {
        var id: String
        var minutes: Double
        var labels: [String]
        var isUnread = false
        var isFromMe = false
        var snippet: String? = "Hello"
        var subject: String? = "Subject"
        var sender: (email: String, name: String?) = ("alice@example.com", "Alice")
    }

    private static func date(_ minutes: Double) -> Date {
        base.addingTimeInterval(minutes * 60)
    }

    /// Saves one conversation (and a second, empty one) with `rows`. Returns
    /// both conversations' objectIDs.
    private func seed(_ rows: [Row]) throws -> (conversation: NSManagedObjectID, other: NSManagedObjectID) {
        let context = stack.newBackgroundContext()
        return try context.performAndWait {
            var labels: [String: Label] = [:]
            func label(_ id: String) -> Label {
                if let label = labels[id] { return label }
                let label = LabelBuilder.custom(id: id, name: id, in: context)
                labels[id] = label
                return label
            }
            for id in ["INBOX", "UNREAD", "SENT", "TRASH", "SPAM", "DRAFT", "STARRED"] {
                _ = label(id)
            }
            let conversation = ConversationBuilder().withParticipantHash("p|bounded").visible().build(in: context)
            let other = ConversationBuilder().withParticipantHash("p|other").visible().build(in: context)
            for row in rows {
                let message = MessageBuilder()
                    .withId(row.id)
                    .withDate(Self.date(row.minutes))
                    .withSender(email: row.sender.email, name: row.sender.name)
                    .inConversation(conversation)
                    .build(in: context)
                message.subject = row.subject
                message.snippet = row.snippet
                message.cleanedSnippet = row.snippet
                message.chatPreviewText = row.snippet
                message.isUnread = row.isUnread
                message.isFromMe = row.isFromMe
                message.labels = Set(row.labels.map(label))
            }
            try context.save()
            return (conversation.objectID, other.objectID)
        }
    }

    /// The reader's snapshot and senders, then the walk's, in `context`.
    /// Pending changes are processed first, as the updater's conversation
    /// fetch processes them before either route runs: until then a deleted
    /// message is still in `conversation.messages`.
    private func compare(
        _ conversationID: NSManagedObjectID,
        in context: NSManagedObjectContext,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let (bounded, walked) = try context.performAndWait { () throws -> (Summary, Summary) in
            context.processPendingChanges()
            let conversation = try XCTUnwrap(context.existingObject(with: conversationID) as? Conversation)
            let overlay = ConversationRollupBoundedReader.overlays(in: context)[conversationID]
            let boundedSnapshot = try ConversationRollupBoundedReader.snapshot(of: conversation, overlay: overlay, in: context)
            let boundedSenders = try ConversationRollupBoundedReader.senders(of: conversation, overlay: overlay, in: context)
            let messages = conversation.messages ?? []
            return (
                Summary(snapshot: boundedSnapshot, senders: boundedSenders),
                Summary(snapshot: .make(from: messages), senders: .walking(messages))
            )
        }
        XCTAssertEqual(bounded.snapshot, walked.snapshot, "snapshot", file: file, line: line)
        XCTAssertEqual(bounded.senders.senderEmails, walked.senders.senderEmails, "sender addresses", file: file, line: line)
        XCTAssertEqual(
            bounded.senders.headerDisplayNamesByEmail,
            walked.senders.headerDisplayNamesByEmail,
            "header names",
            file: file,
            line: line
        )
    }

    private struct Summary {
        let snapshot: ConversationRollupSnapshot
        let senders: ConversationSenderSummary
    }

    private static func message(_ id: String, in context: NSManagedObjectContext) throws -> Message {
        let request = Message.fetchRequest()
        request.predicate = MessagePredicates.id(id)
        return try XCTUnwrap(try context.fetch(request).first)
    }

    private static func label(_ id: String, in context: NSManagedObjectContext) throws -> Label {
        let request = Label.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id)
        return try XCTUnwrap(try context.fetch(request).first)
    }

    /// A conversation whose rule needs every input: unread and read INBOX,
    /// sent mail, a newest visible message with a blank preview (the snippet
    /// comes from an older one), a newer INBOX + TRASH row (in the INBOX
    /// count, out of the visible ones), a SPAM row and a draft.
    private var mixedRows: [Row] {
        [
            Row(id: "m01", minutes: 1, labels: ["INBOX"], isUnread: true),
            Row(id: "m02", minutes: 2, labels: ["INBOX"]),
            Row(id: "m03", minutes: 3, labels: ["SENT"], isFromMe: true, sender: (Self.me, "Me")),
            Row(id: "m04", minutes: 4, labels: ["INBOX", "UNREAD"], isUnread: true, snippet: "The snippet"),
            Row(id: "m05", minutes: 5, labels: ["INBOX"], snippet: "   ", subject: nil),
            Row(id: "m06", minutes: 6, labels: ["INBOX", "TRASH"], isUnread: true, snippet: "Trashed"),
            Row(id: "m07", minutes: 7, labels: ["SPAM"], snippet: "Spam", sender: ("spam@example.com", "Spammer")),
            Row(id: "m08", minutes: 8, labels: ["DRAFT"], isFromMe: true, snippet: "Draft", sender: (Self.me, nil))
        ]
    }

    // MARK: - Stored only

    func testStoredConversation_matchesTheWalk() throws {
        let (conversationID, _) = try seed(mixedRows)
        let context = stack.newBackgroundContext()

        try compare(conversationID, in: context)

        let snippet = try context.performAndWait {
            try ConversationRollupBoundedReader.snapshot(
                of: try XCTUnwrap(context.existingObject(with: conversationID) as? Conversation),
                overlay: nil,
                in: context
            ).snippet
        }
        XCTAssertEqual(snippet, "The snippet", "The newest visible message's preview is blank")
    }

    /// Two visible messages at one date: the greater ID is the newer, in the
    /// walk and in the store's order alike. The rule is fed the tied messages
    /// in both orders, so the answer cannot be whichever came first.
    ///
    /// Revert-check: the ID comparison in
    /// `ConversationRollupSnapshot.MessageInput.isNewer`. Without it the first
    /// tied message added wins, so one of the two orders answers "A".
    func testEqualDates_breakTiesByID() throws {
        let date = Self.date(1)
        let first = ConversationRollupSnapshot.MessageInput(
            id: "tie-a", internalDate: date, labelIDs: ["INBOX"], isUnread: false, isFromMe: false, previewText: "A"
        )
        let second = ConversationRollupSnapshot.MessageInput(
            id: "tie-b", internalDate: date, labelIDs: ["INBOX"], isUnread: false, isFromMe: false, previewText: "B"
        )
        for order in [[first, second], [second, first]] {
            var accumulator = ConversationRollupSnapshot.Accumulator()
            order.forEach { accumulator.add($0) }
            XCTAssertEqual(accumulator.snapshot.snippet, "B", "order \(order.map(\.id))")
        }

        let (conversationID, _) = try seed([
            Row(id: "tie-a", minutes: 1, labels: ["INBOX"], snippet: "A"),
            Row(id: "tie-b", minutes: 1, labels: ["INBOX"], snippet: "B", sender: ("alice@example.com", "Alice Smith"))
        ])
        let context = stack.newBackgroundContext()
        try compare(conversationID, in: context)
    }

    // MARK: - Unsaved changes (the overlay)

    /// Revert-check: the overlay's messages in
    /// `ConversationRollupBoundedReader.snapshot` and, separately, in
    /// `senders`. Leave either out and the unsaved message is missing from
    /// the reader's answer.
    func testUnsavedInsert_isCounted() throws {
        let (conversationID, _) = try seed(mixedRows)
        let context = stack.newBackgroundContext()
        try context.performAndWait {
            let conversation = try XCTUnwrap(context.existingObject(with: conversationID) as? Conversation)
            let inserted = MessageBuilder()
                .withId("m-new")
                .withDate(Self.date(20))
                .withSender(email: "bob@example.com", name: "Bob")
                .inConversation(conversation)
                .build(in: context)
            inserted.snippet = "Newest"
            inserted.isUnread = true
            inserted.labels = [try Self.label("INBOX", in: context)]
        }

        try compare(conversationID, in: context)
    }

    /// Revert-check: `excludedObjectIDs` in the reader's stored reads
    /// (`excludingPredicate`). Without it the store still answers with the
    /// rows as saved, in INBOX. Leaving the overlay's messages out of the
    /// snapshot fails it too: the changed rows are added back from memory.
    func testUnsavedInboxRemovalFromTheNewestInboxRow_isApplied() throws {
        let (conversationID, _) = try seed(mixedRows)
        let context = stack.newBackgroundContext()
        try context.performAndWait {
            try Self.message("m06", in: context).removeFromLabels(try Self.label("INBOX", in: context))
            try Self.message("m05", in: context).removeFromLabels(try Self.label("INBOX", in: context))
        }

        try compare(conversationID, in: context)
    }

    /// Revert-check: `excludedObjectIDs` in the reader's stored reads. Without
    /// it the store still answers with the deleted rows.
    func testUnsavedDeleteOfTheNewestVisibleMessage_isApplied() throws {
        let (conversationID, _) = try seed(mixedRows)
        let context = stack.newBackgroundContext()
        try context.performAndWait {
            context.delete(try Self.message("m05", in: context))
            context.delete(try Self.message("m04", in: context))
        }

        try compare(conversationID, in: context)
    }

    /// A message moved to another conversation and not saved yet: gone from
    /// this one (its saved conversation is still this one) and in the other.
    ///
    /// Revert-check: either the exclusion (the source still counts it) or the
    /// overlay (the destination does not).
    func testUnsavedRehome_leavesTheSourceAndJoinsTheDestination() throws {
        let (conversationID, otherID) = try seed(mixedRows)
        let context = stack.newBackgroundContext()
        try context.performAndWait {
            let other = try XCTUnwrap(context.existingObject(with: otherID) as? Conversation)
            try Self.message("m04", in: context).conversation = other
        }

        try compare(conversationID, in: context)
        try compare(otherID, in: context)
    }

    /// Names: one address with two names whose newest occurrences share a
    /// date (the message ID orders them), and an unsaved message giving the
    /// address a name at that date too.
    ///
    /// The reader's tied names carry the IDs that order them.
    ///
    /// Revert-check: the tied-date ID reads in
    /// `ConversationRollupBoundedReader.senders` (`tiedStoredDates`). Without
    /// them the tied names have no IDs. The overlay half (`senders`' unsaved
    /// messages) fails the comparison with the walk.
    func testSenderNamesWithTiedDates_andAnUnsavedNewerName_matchTheWalk() throws {
        let (conversationID, _) = try seed([
            Row(id: "s1", minutes: 1, labels: ["INBOX"], sender: ("carol@example.com", "Carol")),
            Row(id: "s2", minutes: 2, labels: ["INBOX"], sender: ("carol@example.com", "Carol Smith")),
            Row(id: "s3", minutes: 2, labels: ["INBOX"], sender: ("Carol@Example.com", "C. Smith")),
            Row(id: "s4", minutes: 3, labels: ["INBOX"], sender: ("dave@example.com", nil))
        ])
        let context = stack.newBackgroundContext()
        try compare(conversationID, in: context)
        let tiedIDs = try context.performAndWait {
            let conversation = try XCTUnwrap(context.existingObject(with: conversationID) as? Conversation)
            let senders = try ConversationRollupBoundedReader.senders(of: conversation, overlay: nil, in: context)
            return senders.candidatesByEmail["carol@example.com"]?.mapValues(\.id)
        }
        XCTAssertEqual(tiedIDs?["Carol Smith"], "s2")
        XCTAssertEqual(tiedIDs?["C. Smith"], "s3")


        try context.performAndWait {
            let conversation = try XCTUnwrap(context.existingObject(with: conversationID) as? Conversation)
            let inserted = MessageBuilder()
                .withId("s5")
                .withDate(Self.date(2))
                .withSender(email: "carol@example.com", name: "Carol Q. Smith")
                .inConversation(conversation)
                .build(in: context)
            inserted.labels = [try Self.label("INBOX", in: context)]
        }
        try compare(conversationID, in: context)
    }

    // MARK: - Through the updater

    /// The updater's bounded route stores what its walk stores, title
    /// included.
    ///
    /// HONEST SCOPE: the two routes agree by construction here, so this
    /// survives reverting the route itself; what the route saves is pinned in
    /// `ScaleHubFaultTests`, and the agreement of its inputs by the tests
    /// above.
    @MainActor
    func testUpdateRollupsForModified_boundedRoute_storesWhatTheWalkStores() async throws {
        let (conversationID, _) = try seed(mixedRows)
        let walkedContext = stack.newBackgroundContext()
        let boundedContext = stack.newBackgroundContext()
        let coreDataStack = CoreDataStack(persistentContainerForTesting: stack.persistentContainer)

        let walkedOK = await ConversationRollupUpdater(coreDataStack: coreDataStack, boundedRollupThreshold: .max)
            .updateRollupsForModified(conversationIDs: [conversationID], in: walkedContext, myEmail: Self.me)
        let boundedOK = await ConversationRollupUpdater(coreDataStack: coreDataStack, boundedRollupThreshold: 0)
            .updateRollupsForModified(conversationIDs: [conversationID], in: boundedContext, myEmail: Self.me)

        XCTAssertTrue(walkedOK)
        XCTAssertTrue(boundedOK)
        let walked = try rollupFields(of: conversationID, in: walkedContext)
        let bounded = try rollupFields(of: conversationID, in: boundedContext)
        XCTAssertEqual(bounded, walked)
    }

    /// A bounded read that fails walks the conversation; nothing partial is
    /// applied.
    ///
    /// Revert-check: the walk in `updateBoundedRollups`' catch. Apply an empty
    /// snapshot there instead and the conversation is archived with no date.
    @MainActor
    func testBoundedReadFails_fallsBackToTheWalk() async throws {
        let (conversationID, _) = try seed(mixedRows)
        let walkedContext = stack.newBackgroundContext()
        let failingContext = MessageFetchFailingAfterFirstContext(
            coordinator: stack.persistentContainer.persistentStoreCoordinator
        )
        let coreDataStack = CoreDataStack(persistentContainerForTesting: stack.persistentContainer)

        _ = await ConversationRollupUpdater(coreDataStack: coreDataStack, boundedRollupThreshold: .max)
            .updateRollupsForModified(conversationIDs: [conversationID], in: walkedContext, myEmail: Self.me)
        let updated = await ConversationRollupUpdater(coreDataStack: coreDataStack, boundedRollupThreshold: 0)
            .updateRollupsForModified(conversationIDs: [conversationID], in: failingContext, myEmail: Self.me)

        XCTAssertTrue(updated)
        XCTAssertGreaterThan(failingContext.failedFetches, 0, "No bounded read failed")
        let walked = try rollupFields(of: conversationID, in: walkedContext)
        let fallenBack = try rollupFields(of: conversationID, in: failingContext)
        XCTAssertEqual(fallenBack, walked)
        XCTAssertNotNil(fallenBack.lastMessageDate)
    }

    /// A conversation whose title comes from its messages' From names: two
    /// participants whose stored names are empty, and messages naming them.
    private func seedTitledConversation() throws -> NSManagedObjectID {
        let context = stack.newBackgroundContext()
        return try context.performAndWait {
            let inbox = LabelBuilder.inboxLabel(in: context)
            let conversation = ConversationBuilder().withParticipantHash("p|titled").visible().build(in: context)
            for (email, name) in [("alice@example.com", "Alice Liddell"), ("bob@example.com", "Bob Builder")] {
                let person = PersonBuilder().withEmail(email).noDisplayName().build(in: context)
                let participant = context.insertTestObject(ConversationParticipant.self)
                participant.id = UUID()
                participant.participantRole = .normal
                participant.person = person
                participant.conversation = conversation
                for index in 0..<3 {
                    let message = MessageBuilder()
                        .withId("\(email)-\(index)")
                        .withDate(Self.date(Double(index)))
                        .withSender(email: email, name: name)
                        .inConversation(conversation)
                        .build(in: context)
                    message.labels = [inbox]
                }
            }
            conversation.displayName = "alice@example.com, bob@example.com"
            try context.save()
            return conversation.objectID
        }
    }

    private func storedDisplayName(of conversationID: NSManagedObjectID, in context: NSManagedObjectContext) throws -> String? {
        try context.performAndWait {
            try XCTUnwrap(context.existingObject(with: conversationID) as? Conversation).displayName
        }
    }

    /// The name-only refresh's bounded branch stores the title the walk stores,
    /// a title made from the messages' From names.
    ///
    /// HONEST SCOPE: the two branches agree by construction where the reader
    /// does; this pins that the bounded branch is wired to the title at all.
    @MainActor
    func testUpdateDisplayNamesForConversations_boundedBranch_storesTheWalksTitle() async throws {
        let conversationID = try seedTitledConversation()
        let walkedContext = stack.newBackgroundContext()
        let boundedContext = stack.newBackgroundContext()
        let coreDataStack = CoreDataStack(persistentContainerForTesting: stack.persistentContainer)

        let walkedOK = await ConversationRollupUpdater(coreDataStack: coreDataStack, boundedRollupThreshold: .max)
            .updateDisplayNamesForConversations(conversationIDs: [conversationID], in: walkedContext, myEmail: Self.me)
        let boundedOK = await ConversationRollupUpdater(coreDataStack: coreDataStack, boundedRollupThreshold: 0)
            .updateDisplayNamesForConversations(conversationIDs: [conversationID], in: boundedContext, myEmail: Self.me)

        XCTAssertTrue(walkedOK)
        XCTAssertTrue(boundedOK)
        let walked = try storedDisplayName(of: conversationID, in: walkedContext)
        XCTAssertEqual(try storedDisplayName(of: conversationID, in: boundedContext), walked)
        XCTAssertTrue(walked?.contains("Alice") == true, "The title does not come from the From names: \(walked ?? "nil")")
    }

    /// A bounded sender read that fails walks the messages for the title.
    ///
    /// Revert-check: the walk in `ConversationRollupUpdater.boundedSenders`'
    /// catch. Answer an empty summary there and the title loses the From names.
    @MainActor
    func testBoundedSenderReadFails_fallsBackToTheWalksTitle() async throws {
        let conversationID = try seedTitledConversation()
        let walkedContext = stack.newBackgroundContext()
        let failingContext = MessageFetchFailingAfterFirstContext(
            coordinator: stack.persistentContainer.persistentStoreCoordinator
        )
        let coreDataStack = CoreDataStack(persistentContainerForTesting: stack.persistentContainer)

        _ = await ConversationRollupUpdater(coreDataStack: coreDataStack, boundedRollupThreshold: .max)
            .updateDisplayNamesForConversations(conversationIDs: [conversationID], in: walkedContext, myEmail: Self.me)
        let updated = await ConversationRollupUpdater(coreDataStack: coreDataStack, boundedRollupThreshold: 0)
            .updateDisplayNamesForConversations(conversationIDs: [conversationID], in: failingContext, myEmail: Self.me)

        XCTAssertTrue(updated)
        XCTAssertGreaterThan(failingContext.failedFetches, 0, "No bounded sender read failed")
        XCTAssertEqual(
            try storedDisplayName(of: conversationID, in: failingContext),
            try storedDisplayName(of: conversationID, in: walkedContext)
        )
    }

    private struct RollupFields: Equatable {
        let lastMessageDate: Date?
        let snippet: String?
        let hasInbox: Bool
        let inboxUnreadCount: Int32
        let latestInboxDate: Date?
        let archivedAt: Date?
        let displayName: String?
    }

    private func rollupFields(of conversationID: NSManagedObjectID, in context: NSManagedObjectContext) throws -> RollupFields {
        try context.performAndWait {
            let conversation = try XCTUnwrap(context.existingObject(with: conversationID) as? Conversation)
            return RollupFields(
                lastMessageDate: conversation.lastMessageDate,
                snippet: conversation.snippet,
                hasInbox: conversation.hasInbox,
                inboxUnreadCount: conversation.inboxUnreadCount,
                latestInboxDate: conversation.latestInboxDate,
                archivedAt: conversation.archivedAt,
                displayName: conversation.displayName
            )
        }
    }
}

/// A store-backed context whose `Message` fetches fail after the first one
/// (the updater's stored-count read), so the bounded reader's own reads fail.
/// Counts and relationship faults go to the store as usual.
///
/// `@unchecked Sendable`: `lock` guards `messageFetches` and `failures`; Core
/// Data's own state stays on the context's private queue.
private final class MessageFetchFailingAfterFirstContext: NSManagedObjectContext, @unchecked Sendable {
    private let lock = NSLock()
    private var messageFetches = 0
    private var failures = 0

    init(coordinator: NSPersistentStoreCoordinator) {
        super.init(concurrencyType: .privateQueueConcurrencyType)
        persistentStoreCoordinator = coordinator
        mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    required init?(coder: NSCoder) {
        fatalError("not supported in tests")
    }

    var failedFetches: Int { lock.withLock { failures } }

    override func __execute(_ request: NSFetchRequest<NSFetchRequestResult>) throws -> [Any] {
        guard request.entityName == "Message" else { return try super.__execute(request) }
        let fails: Bool = lock.withLock {
            messageFetches += 1
            if messageFetches > 1 { failures += 1 }
            return messageFetches > 1
        }
        if fails {
            throw NSError(domain: "MessageFetchFailingAfterFirstContext", code: 1)
        }
        return try super.__execute(request)
    }
}
