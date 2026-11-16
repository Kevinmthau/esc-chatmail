import XCTest
import CoreData
@testable import esc_chatmail

/// What one small write does to a fresh context on a mailbox of S2 size
/// (`ScaleStoreShape.s2`: 120k messages), driven through the sync path's own
/// code. Part of the scale harness (`docs/scalability-review.md`, step 4 of
/// "Suggested order"); it runs only under `./Scripts/codex-test.sh --performance`.
///
/// The INBOX label and the user's own Person are each related to most of the
/// mailbox. Any write that touches one of those relationships makes Core Data
/// read the whole of it into the writing context, and every sync run, every
/// background task and every cleanup pass starts with a context that has not
/// read it yet (review item `inverse-tomany-hub-fault-tax`). So these tests
/// ask two things of the context after the write and its save: are the two
/// relationships still faults, and how many objects did the context register.
/// Neither is a timing, and neither can be seen on an in-memory store or on a
/// store of a few hundred rows.
///
/// KNOWN GAPS. Today every one of these writes reads a hub, so the assertions
/// that say it must not are wrapped in `XCTExpectFailure`, each naming what
/// was measured (iOS 27.0 simulator, 2026-11-16). `XCTExpectFailure` is
/// strict: once the fix lands the assertion passes, the test fails with "no
/// failure was recorded", and the wrapper comes off in that fix's own change,
/// which gives the assertion its `Revert-check:`. An assertion outside a
/// wrapper holds today and must keep holding.
///
/// HONEST SCOPE: nothing here can be revert-checked against a fix that does
/// not exist yet. What each test checks outside its wrappers (the write
/// happened, the row is as expected) is what keeps a broken fixture from
/// counting as the expected failure.
final class ScaleHubFaultTests: XCTestCase {
    private static let selfEmail = ScaleStorePlan.selfEmail

    /// Far above what one message needs and far below either hub (97,031
    /// and 120,000 members), so the bound says "in proportion to the write"
    /// without pinning a count that moves with every rollup change. Of the
    /// 217,062 objects the new-message write leaves registered today, 31 are
    /// not a hub's members.
    private static let registeredObjectBound = 1_000

    /// Someone who writes to the user now and then, not one of the 25 people
    /// who post to the seeded mailing list: a sender's own
    /// `messageParticipations` is read by a new message too, and a list
    /// sender has 800 of them.
    private static let ordinarySenderIndex = 4_000

    private struct ContextState {
        let inboxMembersAreFault: Bool
        let selfParticipationsAreFault: Bool
        let registeredObjectCount: Int
    }

    /// The INBOX label and the user's own Person in the context under test.
    /// Unchecked: the rows are touched only inside that context's `perform`.
    private final class Hubs: @unchecked Sendable {
        let inbox: Label
        let me: Person

        init(inbox: Label, me: Person) {
            self.inbox = inbox
            self.me = me
        }
    }

    private var stack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!
    private var manifest: ScaleStoreManifest!

    override func setUp() async throws {
        try await super.setUp()
        let seeded = try ScaleStoreTemplate.s2.makeStack()
        stack = seeded.stack
        manifest = seeded.manifest
        coreDataStack = CoreDataStack(persistentContainerForTesting: seeded.stack.persistentContainer)
        await ModificationTracker.shared.reset()
    }

    override func tearDown() async throws {
        await ModificationTracker.shared.reset()
        coreDataStack = nil
        manifest = nil
        stack = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func save(_ context: NSManagedObjectContext) async throws {
        try await context.perform {
            XCTAssertTrue(context.hasChanges, "The write under test staged nothing")
            try context.save()
        }
    }

    /// The two hub rows of a context that has read nothing else, held for the
    /// length of the test. Held, because a context keeps only weak references
    /// to what it has registered: after the save nothing else holds a label
    /// that only a history record touched, the row is dropped with whatever
    /// its relationship had read, and a second look finds a new row whose
    /// relationship is a fault again. Measured here before the rows were held:
    /// the label removal and the deletion both read the hubs and both left
    /// the context with 0 registered objects.
    ///
    /// Holding a row does not read its relationships, which the first two
    /// assertions say.
    private func holdHubs(in context: NSManagedObjectContext) async throws -> Hubs {
        try await context.perform {
            let labelRequest = NSFetchRequest<Label>(entityName: "Label")
            labelRequest.predicate = NSPredicate(format: "id == %@", "INBOX")
            let inbox = try XCTUnwrap(try context.fetch(labelRequest).first)

            let personRequest = NSFetchRequest<Person>(entityName: "Person")
            personRequest.predicate = NSPredicate(format: "email == %@", Self.selfEmail)
            let me = try XCTUnwrap(try context.fetch(personRequest).first)

            XCTAssertTrue(inbox.hasFault(forRelationshipNamed: "messages"))
            XCTAssertTrue(me.hasFault(forRelationshipNamed: "messageParticipations"))
            return Hubs(inbox: inbox, me: me)
        }
    }

    /// Reads the context as the write and its save left it.
    private func state(of context: NSManagedObjectContext, holding hubs: Hubs) async -> ContextState {
        await context.perform {
            ContextState(
                inboxMembersAreFault: hubs.inbox.hasFault(forRelationshipNamed: "messages"),
                selfParticipationsAreFault: hubs.me.hasFault(forRelationshipNamed: "messageParticipations"),
                registeredObjectCount: context.registeredObjects.count
            )
        }
    }

    /// The stored message's labels and participant count, read in a context of
    /// its own so the read does not change the context under test.
    private func storedMessage(id: String) throws -> (labels: Set<String>, participantCount: Int)? {
        let context = stack.viewContext
        return try context.performAndWait {
            let request = NSFetchRequest<Message>(entityName: "Message")
            request.predicate = MessagePredicates.id(id)
            guard let message = try context.fetch(request).first else { return nil }
            return (Set((message.labels ?? []).map(\.id)), message.participants?.count ?? 0)
        }
    }

    // MARK: - A new message

    /// The commonest write there is: an incremental sync that found one new
    /// message. `MessagePersister.saveMessages` and the save, in a context
    /// that has read nothing, as each sync run's context is.
    @MainActor
    func testPersistingOneNewMessage_readsNeitherHubIntoTheSyncContext() async throws {
        let persister = MessagePersister(
            coreDataStack: coreDataStack,
            messageProcessor: MessageProcessor(),
            saveHTML: { _, messageId in .savedWithoutWriting(messageId: messageId) },
            conversationManager: ConversationManager(currentUserEmail: { Self.selfEmail })
        )
        let context = coreDataStack.newBackgroundContext()
        let newMessage = GmailMessageBuilder()
            .withId("scale-new-message")
            .withThreadId("scale-new-thread")
            .withLabels(["INBOX", "UNREAD"])
            .withFrom(ScaleStoreSeeder.personEmail(at: Self.ordinarySenderIndex), name: "An ordinary sender")
            .withTo([Self.selfEmail])
            .withSubject("New mail")
            .withSnippet("New mail")
            .build()

        let hubs = try await holdHubs(in: context)
        let report = try await persister.saveMessages([newMessage], myAliases: [Self.selfEmail], in: context)
        try await save(context)
        let state = await state(of: context, holding: hubs)

        XCTAssertEqual(report.persistedIds, ["scale-new-message"])
        let stored = try XCTUnwrap(try storedMessage(id: "scale-new-message"))
        XCTAssertEqual(stored.labels, ["INBOX", "UNREAD"])
        XCTAssertEqual(stored.participantCount, 2)

        XCTExpectFailure("inverse-tomany-hub-fault-tax: a new INBOX message reads all 97,031 INBOX members") {
            XCTAssertTrue(state.inboxMembersAreFault)
        }
        XCTExpectFailure("inverse-tomany-hub-fault-tax: a new message reads all 120,000 of the user's participations") {
            XCTAssertTrue(state.selfParticipationsAreFault)
        }
        XCTExpectFailure("inverse-tomany-hub-fault-tax: one new message leaves 217,062 objects registered") {
            XCTAssertLessThan(state.registeredObjectCount, Self.registeredObjectBound)
        }
    }

    // MARK: - A label change

    /// Gmail reports that one message left the inbox (archived elsewhere).
    /// `HistoryProcessor.processLabelRemovals` and the save.
    func testRemovingInboxFromOneMessage_readsNeitherHubIntoTheSyncContext() async throws {
        let messageID = manifest.ordinaryConversationInboxMessageID
        let context = coreDataStack.newBackgroundContext()
        let hubs = try await holdHubs(in: context)

        try await HistoryProcessor(coreDataStack: coreDataStack).processLabelRemovals(
            [HistoryLabelRemoved(message: MessageListItem(id: messageID, threadId: nil), labelIds: ["INBOX"])],
            in: context,
            syncStartTime: nil,
            modificationTransaction: nil
        )
        try await save(context)
        let state = await state(of: context, holding: hubs)

        let stored = try XCTUnwrap(try storedMessage(id: messageID))
        XCTAssertFalse(stored.labels.contains("INBOX"))

        XCTExpectFailure("inverse-tomany-hub-fault-tax: removing INBOX from one message reads every INBOX member") {
            XCTAssertTrue(state.inboxMembersAreFault)
        }
        // A label change has nothing to do with who is on the message, and
        // does not read the user's participations today either.
        XCTAssertTrue(state.selfParticipationsAreFault)
        XCTExpectFailure("inverse-tomany-hub-fault-tax: one label removal leaves 97,032 objects registered") {
            XCTAssertLessThan(state.registeredObjectCount, Self.registeredObjectBound)
        }
    }

    // MARK: - A deletion

    /// Gmail reports that one message was deleted.
    /// `HistoryProcessor.processMessageDeletions` and the save.
    func testDeletingOneMessage_readsNeitherHubIntoTheSyncContext() async throws {
        let messageID = manifest.ordinaryConversationInboxMessageID
        let context = coreDataStack.newBackgroundContext()
        let hubs = try await holdHubs(in: context)

        try await HistoryProcessor(coreDataStack: coreDataStack).processMessageDeletions(
            [HistoryMessageDeleted(message: MessageListItem(id: messageID, threadId: nil))],
            modificationTransaction: nil,
            in: context
        )
        try await save(context)
        let state = await state(of: context, holding: hubs)

        XCTAssertNil(try storedMessage(id: messageID))

        XCTExpectFailure("inverse-tomany-hub-fault-tax: deleting one INBOX message reads every INBOX member") {
            XCTAssertTrue(state.inboxMembersAreFault)
        }
        XCTExpectFailure("inverse-tomany-hub-fault-tax: deleting one message reads all of the user's participations") {
            XCTAssertTrue(state.selfParticipationsAreFault)
        }
        XCTExpectFailure("inverse-tomany-hub-fault-tax: one deletion leaves 217,031 objects registered") {
            XCTAssertLessThan(state.registeredObjectCount, Self.registeredObjectBound)
        }
    }
}
