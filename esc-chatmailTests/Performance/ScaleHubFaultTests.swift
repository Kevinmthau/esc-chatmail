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
/// The context under test keeps what it registers (`makeContextUnderTest`).
/// A context holds a row it has not changed weakly, so after the save a row
/// nothing else holds is gone, with whatever its relationships had read:
/// measured on an ordinary context, a label removal and a deletion that each
/// read a hub left 0 objects registered and both relationships reading as
/// untouched faults. Keeping the rows is the only difference from a sync
/// run's context, and it changes what the context forgets, not what it reads.
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
    /// 217,062 objects the new-message write registers today, 29 are not a
    /// hub's members.
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

    /// A context that has read nothing, as each sync run's is, and that keeps
    /// every row it registers for as long as it lives. Without that, what
    /// `state(of:)` reads after the save is only what something else still
    /// holds: the count misses every row the write read and let go of, and a
    /// hub row the write read is a new row by then, whose relationship is a
    /// fault again.
    private func makeContextUnderTest() -> NSManagedObjectContext {
        let context = coreDataStack.newBackgroundContext()
        context.performAndWait {
            context.retainsRegisteredObjects = true
        }
        return context
    }

    /// Reads the context as the write and its save left it.
    private func state(of context: NSManagedObjectContext) async throws -> ContextState {
        try await context.perform {
            // Counted first: the two fetches below register a hub row the
            // write never touched.
            let registeredObjectCount = context.registeredObjects.count

            // A fetch returns the row the context already holds, as the write
            // left it, and a row the write never registered comes back with
            // its relationships unread.
            let labelRequest = NSFetchRequest<Label>(entityName: "Label")
            labelRequest.predicate = NSPredicate(format: "id == %@", "INBOX")
            let inbox = try XCTUnwrap(try context.fetch(labelRequest).first)

            let personRequest = NSFetchRequest<Person>(entityName: "Person")
            personRequest.predicate = NSPredicate(format: "email == %@", Self.selfEmail)
            let me = try XCTUnwrap(try context.fetch(personRequest).first)

            return ContextState(
                inboxMembersAreFault: inbox.hasFault(forRelationshipNamed: "messages"),
                selfParticipationsAreFault: me.hasFault(forRelationshipNamed: "messageParticipations"),
                registeredObjectCount: registeredObjectCount
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

    // MARK: - The measure

    /// The count is of everything the write registered, through any
    /// relationship, and not only of what the two hubs hold: a write that
    /// reads the largest chat's 20,000 messages is over the bound although it
    /// reads neither hub. And a context that read neither hub says so.
    ///
    /// Revert-check: `retainsRegisteredObjects = true` in
    /// `makeContextUnderTest`. The context then lets go of the conversation
    /// after the save, and of its messages with it, and the count is of a
    /// handful of rows.
    func testRegisteredObjectCount_countsWhatAWriteReadThroughAnyRelationship() async throws {
        let conversationID = manifest.largestConversationID
        let messageCount = manifest.largestConversationMessageCount
        let context = makeContextUnderTest()

        try await context.perform {
            let request = NSFetchRequest<Conversation>(entityName: "Conversation")
            request.predicate = NSPredicate(format: "id == %@", conversationID as CVarArg)
            let conversation = try XCTUnwrap(try context.fetch(request).first)
            XCTAssertEqual(conversation.messages?.count, messageCount)
            conversation.snippet = "A write that read the whole chat"
        }
        try await save(context)
        let state = try await state(of: context)

        XCTAssertGreaterThan(messageCount, Self.registeredObjectBound)
        XCTAssertGreaterThan(state.registeredObjectCount, messageCount)
        XCTAssertTrue(state.inboxMembersAreFault)
        XCTAssertTrue(state.selfParticipationsAreFault)
    }

    // MARK: - A rollup

    /// The run's rollup of the largest chat (20,000 messages, a mailing
    /// list), through `ConversationRollupUpdater.updateRollupsForModified` on a
    /// context that has read nothing. It reads the chat from bounded queries
    /// (`ConversationRollupBoundedReader`) and its kept list title reads no
    /// sender (architecture review 2026-11, data-model#4).
    ///
    /// Revert-check: the bounded route (`partitionForRollup` sending a
    /// conversation over `ConversationRollupBoundedReader.messageCountThreshold`
    /// to the reader). Walk every conversation and the rollup registers every
    /// message of the chat: 20,063 objects (iOS 27.0 simulator, 2026-11-28).
    @MainActor
    func testRollingUpTheLargestChat_readsABoundedNumberOfRows() async throws {
        let context = makeContextUnderTest()
        let largestConversationID = manifest.largestConversationID
        let conversationID = try await context.perform {
            let request = NSFetchRequest<Conversation>(entityName: "Conversation")
            request.predicate = NSPredicate(format: "id == %@", largestConversationID as CVarArg)
            return try XCTUnwrap(try context.fetch(request).first).objectID
        }

        let updated = await ConversationRollupUpdater(coreDataStack: coreDataStack)
            .updateRollupsForModified(conversationIDs: [conversationID], in: context, myEmail: Self.selfEmail)
        let state = try await state(of: context)

        XCTAssertTrue(updated)
        let lastMessageDate = try await context.perform {
            try XCTUnwrap(context.existingObject(with: conversationID) as? Conversation).lastMessageDate
        }
        XCTAssertNotNil(lastMessageDate)
        XCTAssertLessThan(state.registeredObjectCount, Self.registeredObjectBound)
        XCTAssertTrue(state.inboxMembersAreFault)
        XCTAssertTrue(state.selfParticipationsAreFault)
    }

    /// The run's rollup of the largest chat as a sync run makes it, inside
    /// `ConversationRollupMutationSerializer.performThrowingSyncMutation`, on a
    /// chat whose every message carries a local change (`localModifiedAt`, set
    /// by every mark-read and every archive or spam of the chat, and never
    /// cleared). The serializer first restores newer local read state
    /// (`preserveNewerLocalReadState`), and that must read the chat's local
    /// changes as values, not load the messages into the sync context.
    ///
    /// Revert-check: `registeredObject(for:)` in `preserveNewerLocalReadState`.
    /// With `existingObject(with:)` every message with a local change is
    /// registered in the sync context: 20,063 objects (iOS 27.0 simulator,
    /// 2026-11-28). HONEST SCOPE: the store read's own cost (it was full rows
    /// with bodies, in a context of its own, and is now values) is not what
    /// this counts.
    @MainActor
    func testSyncMutationOfTheLargestChat_withLocalChanges_readsABoundedNumberOfRows() async throws {
        let largestConversationID = manifest.largestConversationID
        let expectedCount = manifest.largestConversationMessageCount
        let marker = stack.newBackgroundContext()
        let conversationID = try await marker.perform {
            let request = NSFetchRequest<Conversation>(entityName: "Conversation")
            request.predicate = NSPredicate(format: "id == %@", largestConversationID as CVarArg)
            let conversationID = try XCTUnwrap(try marker.fetch(request).first).objectID
            let update = NSBatchUpdateRequest(entityName: "Message")
            update.predicate = NSPredicate(format: "conversation == %@", conversationID)
            update.propertiesToUpdate = ["localModifiedAt": Date()]
            update.resultType = .updatedObjectsCountResultType
            let result = try XCTUnwrap(try marker.execute(update) as? NSBatchUpdateResult)
            XCTAssertEqual(result.result as? Int, expectedCount)
            return conversationID
        }
        let context = makeContextUnderTest()
        let coreDataStack = self.coreDataStack!

        let updated = try await ConversationRollupMutationSerializer().performThrowingSyncMutation(
            conversationIDs: [conversationID],
            in: context
        ) {
            await ConversationRollupUpdater(coreDataStack: coreDataStack)
                .updateRollupsForModified(conversationIDs: [conversationID], in: context, myEmail: Self.selfEmail)
        }
        let state = try await state(of: context)

        XCTAssertTrue(updated)
        XCTAssertLessThan(state.registeredObjectCount, Self.registeredObjectBound)
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
        let context = makeContextUnderTest()
        let newMessage = GmailMessageBuilder()
            .withId("scale-new-message")
            .withThreadId("scale-new-thread")
            .withLabels(["INBOX", "UNREAD"])
            .withFrom(ScaleStoreSeeder.personEmail(at: Self.ordinarySenderIndex), name: "An ordinary sender")
            .withTo([Self.selfEmail])
            .withSubject("New mail")
            .withSnippet("New mail")
            .build()

        let report = try await persister.saveMessages([newMessage], myAliases: [Self.selfEmail], in: context)
        try await save(context)
        let state = try await state(of: context)

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
        XCTExpectFailure("inverse-tomany-hub-fault-tax: one new message registers 217,062 objects") {
            XCTAssertLessThan(state.registeredObjectCount, Self.registeredObjectBound)
        }
    }

    // MARK: - A label change

    /// Gmail reports that one message left the inbox (archived elsewhere).
    /// `HistoryProcessor.processLabelRemovals` and the save.
    func testRemovingInboxFromOneMessage_readsNeitherHubIntoTheSyncContext() async throws {
        let messageID = manifest.ordinaryConversationInboxMessageID
        let context = makeContextUnderTest()

        try await HistoryProcessor(coreDataStack: coreDataStack).processLabelRemovals(
            [HistoryLabelRemoved(message: MessageListItem(id: messageID, threadId: nil), labelIds: ["INBOX"])],
            in: context,
            syncStartTime: nil,
            modificationTransaction: nil
        )
        try await save(context)
        let state = try await state(of: context)

        let stored = try XCTUnwrap(try storedMessage(id: messageID))
        XCTAssertFalse(stored.labels.contains("INBOX"))

        XCTExpectFailure("inverse-tomany-hub-fault-tax: removing INBOX from one message reads every INBOX member") {
            XCTAssertTrue(state.inboxMembersAreFault)
        }
        // A label change has nothing to do with who is on the message, and
        // does not read the user's participations today either.
        XCTAssertTrue(state.selfParticipationsAreFault)
        XCTExpectFailure("inverse-tomany-hub-fault-tax: one label removal registers 97,040 objects") {
            XCTAssertLessThan(state.registeredObjectCount, Self.registeredObjectBound)
        }
    }

    // MARK: - A deletion

    /// Gmail reports that one message was deleted.
    /// `HistoryProcessor.processMessageDeletions` and the save.
    func testDeletingOneMessage_readsNeitherHubIntoTheSyncContext() async throws {
        let messageID = manifest.ordinaryConversationInboxMessageID
        let context = makeContextUnderTest()

        try await HistoryProcessor(coreDataStack: coreDataStack).processMessageDeletions(
            [HistoryMessageDeleted(message: MessageListItem(id: messageID, threadId: nil))],
            modificationTransaction: nil,
            in: context
        )
        try await save(context)
        let state = try await state(of: context)

        XCTAssertNil(try storedMessage(id: messageID))

        XCTExpectFailure("inverse-tomany-hub-fault-tax: deleting one INBOX message reads every INBOX member") {
            XCTAssertTrue(state.inboxMembersAreFault)
        }
        XCTExpectFailure("inverse-tomany-hub-fault-tax: deleting one message reads all of the user's participations") {
            XCTAssertTrue(state.selfParticipationsAreFault)
        }
        // 2,885 of them are members of neither hub: 2,841 messages and the
        // rows of the message's other people. Which read brings those
        // messages in was not looked into; the count before this context
        // kept its rows (217,031) could not see them.
        XCTExpectFailure("inverse-tomany-hub-fault-tax: one deletion registers 219,916 objects") {
            XCTAssertLessThan(state.registeredObjectCount, Self.registeredObjectBound)
        }
    }
}
