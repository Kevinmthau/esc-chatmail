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
/// KNOWN GAPS. Model 9 took the user's Person off as a hub (it dropped the
/// inverse `Person.messageParticipations`), so no write here reads the user's
/// participations. Every write but the unchanged refetch still reads the INBOX
/// label's members, so the assertions that say it must not are wrapped in
/// `XCTExpectFailure`, each naming what was measured (iOS 27.0 simulator,
/// 2026-11-16 and 2026-11-28); they come off with the denormalized label
/// flags. `XCTExpectFailure` is
/// strict: once the fix lands the assertion passes, the test fails with "no
/// failure was recorded", and the wrapper comes off in that fix's own change,
/// which gives the assertion its `Revert-check:`. An assertion outside a
/// wrapper holds today and must keep holding.
///
/// HONEST SCOPE: a write whose fix does not exist yet cannot be revert-checked;
/// what each such test checks outside its wrappers (the write happened, the
/// row is as expected) is what keeps a broken fixture from counting as the
/// expected failure. The unchanged refetch's fix exists, and its test names its
/// `Revert-check:`.
final class ScaleHubFaultTests: XCTestCase {
    private static let selfEmail = ScaleStorePlan.selfEmail

    /// Far above what one message needs and far below either hub (97,031
    /// and 120,000 members), so the bound says "in proportion to the write"
    /// without pinning a count that moves with every rollup change. Of the
    /// 217,062 objects the new-message write registers today, 29 are not a
    /// hub's members.
    private static let registeredObjectBound = 1_000

    /// Someone who writes to the user now and then, not one of the 25 people
    /// who post to the seeded mailing list: until model 9 a sender's own
    /// `messageParticipations` was read by a new message too, and a list
    /// sender has 800 of them.
    private static let ordinarySenderIndex = 4_000

    private struct ContextState {
        let inboxMembersAreFault: Bool
        /// How many participant rows the context registered. Until model 9
        /// a write that set a participant's person read the user's whole
        /// `Person.messageParticipations` (120,000 rows at S2); model 9 has no
        /// such inverse to ask `hasFault` of, so the rows are counted.
        let registeredParticipantCount: Int
        let registeredObjectCount: Int

        /// The user's participations were not read: far fewer participant
        /// rows than the self hub holds.
        var selfParticipationsAreUnread: Bool {
            registeredParticipantCount < ScaleHubFaultTests.registeredObjectBound
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
            // Counted first: the fetch below registers a hub row the write
            // never touched.
            let registeredObjectCount = context.registeredObjects.count
            let registeredParticipantCount = context.registeredObjects.filter { $0 is MessageParticipant }.count

            // A fetch returns the row the context already holds, as the write
            // left it, and a row the write never registered comes back with
            // its relationships unread.
            let labelRequest = NSFetchRequest<Label>(entityName: "Label")
            labelRequest.predicate = NSPredicate(format: "id == %@", "INBOX")
            let inbox = try XCTUnwrap(try context.fetch(labelRequest).first)

            return ContextState(
                inboxMembersAreFault: inbox.hasFault(forRelationshipNamed: "messages"),
                registeredParticipantCount: registeredParticipantCount,
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
        XCTAssertTrue(state.selfParticipationsAreUnread)
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
        // Revert-check: model 9's inverse-less `MessageParticipant.person`.
        // Move the model 9 directory out of the `.xcdatamodeld` and mark
        // model 8 current (the build rewrites `.xccurrentversion` alone back
        // to 9): the new message registers 120,025 participant rows.
        XCTAssertTrue(state.selfParticipationsAreUnread, "\(state.registeredParticipantCount) participant rows")
        XCTExpectFailure("inverse-tomany-hub-fault-tax: one new message registers 217,062 objects") {
            XCTAssertLessThan(state.registeredObjectCount, Self.registeredObjectBound)
        }
    }

    // MARK: - A send

    /// A New Message, created as the app creates it: on the main-queue view
    /// context (`GmailSendService.createOptimisticMessage`), with the user's
    /// own address as its From row (architecture review 2026-11,
    /// coredata-stack#4). Setting that row's person read every one of the
    /// user's participations into the view context, on the main thread, until
    /// model 9 dropped the inverse. The review's other fix, building the
    /// graph in a private context, was settled against: it conflicts with
    /// gap-change-propagation-pipeline#1 (the view-context reads after
    /// creation), and model 9 removes the cost it was for.
    ///
    /// Revert-check: model 9's inverse-less `MessageParticipant.person`. Move
    /// the model 9 directory out of the `.xcdatamodeld` and mark model 8
    /// current: the send registers 120,025 participant rows and 120,035
    /// objects.
    @MainActor
    func testSendingANewMessage_onTheViewContext_readsNoneOfTheUsersParticipations() async throws {
        let viewContext = stack.makeMainQueueViewContext()
        viewContext.retainsRegisteredObjects = true
        let authSession = AuthSession(
            tokenManagerProvider: { MockTokenManager() },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(suiteName: "ScaleHubFaultTests.\(UUID().uuidString)")!,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
        authSession.userEmail = Self.selfEmail
        authSession.userName = "Me"
        let recipient = ScaleStoreSeeder.personEmail(at: Self.ordinarySenderIndex)
        let sendService = GmailSendService(viewContext: viewContext, authSession: authSession)

        let handle = try await sendService.createOptimisticMessage(
            to: [recipient],
            body: "Hello",
            optimisticConversation: .participantHash(calculateParticipantHash(from: [normalizedEmail(recipient)]))
        )

        let message = try XCTUnwrap(sendService.fetchMessageSync(byID: handle.optimisticMessageID))
        XCTAssertTrue(message.participants?.contains { $0.person?.email == Self.selfEmail } == true)
        let registeredParticipants = viewContext.registeredObjects.filter { $0 is MessageParticipant }.count
        XCTAssertLessThan(registeredParticipants, Self.registeredObjectBound)
        XCTAssertLessThan(viewContext.registeredObjects.count, Self.registeredObjectBound)
    }

    // MARK: - A refetch

    /// A stored message fetched again with nothing changed in Gmail: what a
    /// held cursor's re-scan and a history recovery's re-list do to every row
    /// they meet. `MessagePersister.saveMessages` takes the update path, and
    /// the save. The refetch carries exactly the row's labels, so nothing about
    /// the message's mailboxes changed and nothing about them is written.
    ///
    /// Revert-check: `ExistingMessageLabelDiff` in
    /// `MessagePersister.performExistingMessageUpdate`. Put back the old
    /// `existingMessage.labels = nil` and re-add, and the refetch reads every
    /// INBOX member and registers 99,877 objects (measured with the two
    /// assertions below wrapped in `XCTExpectFailure`, iOS 27.0 simulator,
    /// 2026-11-28).
    @MainActor
    func testRefetchingAStoredMessageWithUnchangedLabels_readsNeitherHubIntoTheSyncContext() async throws {
        let messageID = manifest.ordinaryConversationInboxMessageID
        let stored = try XCTUnwrap(try storedRow(id: messageID))
        XCTAssertTrue(stored.labels.contains("INBOX"))
        let persister = MessagePersister(
            coreDataStack: coreDataStack,
            messageProcessor: MessageProcessor(),
            saveHTML: { _, messageId in .savedWithoutWriting(messageId: messageId) },
            conversationManager: ConversationManager(currentUserEmail: { Self.selfEmail })
        )
        let context = makeContextUnderTest()
        let refetch = GmailMessageBuilder()
            .withId(messageID)
            .withThreadId(stored.threadID)
            .withLabels(stored.labelOrder)
            .withInternalDate(stored.internalDate)
            .withFrom(stored.senderEmail, name: stored.senderName)
            .withTo([Self.selfEmail])
            .withSubject(stored.subject)
            .withSnippet(stored.snippet)
            .build()

        let report = try await persister.saveMessages([refetch], myAliases: [Self.selfEmail], in: context)
        try await save(context)
        let state = try await state(of: context)

        XCTAssertEqual(report.persistedIds, [messageID])
        XCTAssertEqual(try XCTUnwrap(try storedMessage(id: messageID)).labels, stored.labels)

        XCTAssertTrue(state.inboxMembersAreFault)
        XCTAssertTrue(state.selfParticipationsAreUnread)
        XCTAssertLessThan(state.registeredObjectCount, Self.registeredObjectBound)
    }

    /// The fields of a stored row a refetch of it carries, read in a context of
    /// its own so the read does not change the context under test.
    private func storedRow(id: String) throws -> (
        labels: Set<String>,
        labelOrder: [String],
        threadID: String,
        internalDate: Date,
        senderEmail: String,
        senderName: String?,
        subject: String,
        snippet: String
    )? {
        let context = stack.viewContext
        return try context.performAndWait {
            let request = NSFetchRequest<Message>(entityName: "Message")
            request.predicate = MessagePredicates.id(id)
            guard let message = try context.fetch(request).first else { return nil }
            let labels = (message.labels ?? []).map(\.id)
            return (
                Set(labels),
                labels.sorted(),
                message.gmThreadId,
                message.internalDate,
                message.senderEmailValue ?? "",
                message.senderNameValue,
                message.subject ?? "",
                message.snippet ?? ""
            )
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
        XCTAssertTrue(state.selfParticipationsAreUnread)
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
        // Revert-check: model 9's inverse-less `MessageParticipant.person`.
        // Move the model 9 directory aside and mark model 8 current: 120,038
        // participant rows (the deletion cascaded to the participants, whose
        // person's set was read to nullify them).
        XCTAssertTrue(state.selfParticipationsAreUnread, "\(state.registeredParticipantCount) participant rows")
        // 2,885 of them are members of neither hub: 2,841 messages and the
        // rows of the message's other people. Which read brings those
        // messages in was not looked into; the count before this context
        // kept its rows (217,031) could not see them.
        XCTExpectFailure("inverse-tomany-hub-fault-tax: one deletion registers 219,916 objects") {
            XCTAssertLessThan(state.registeredObjectCount, Self.registeredObjectBound)
        }
    }
}
