import XCTest
import Contacts
import CoreData
@testable import esc_chatmail

/// Covers `DataCleanupService.unifyConversationsByContactIfNeeded`: the pass
/// that makes one chat of the chats a person's two addresses opened, once
/// their contact card lists both, and the participant-hash repair it runs
/// (`fixAndMergeIncorrectParticipantHashes`, scoped to the changed addresses).
///
/// The address book is a stub (`makeContacts`); nothing here reads the real
/// Contacts, and the shared `ContactLinkedAddressStore` holds nothing under
/// unit tests.
///
/// Fixtures, saves, and assertions go through a main-queue context from
/// `TestCoreDataStack.makeMainQueueViewContext()`, never `stack.viewContext`,
/// which is private-queue. The test bodies use it directly, so `@MainActor` on
/// the class is what puts those accesses on-queue; see that helper for what the
/// private-queue shape races. The pass under test works on its own background
/// contexts.
@MainActor
final class ContactUnificationCleanupTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!
    private var context: NSManagedObjectContext!
    private var migrationFlags: InMemoryMigrationFlagStore!
    private var inbox: Label!

    private nonisolated static let me = "me@example.com"
    /// One person's two addresses. `home` sorts first, so it is the address
    /// that stands for the person in a hash once a card links the two.
    private nonisolated static let work = "morgan@corp.example"
    private nonisolated static let home = "m.vale@mail.example"
    private nonisolated static let carol = "carol@example.com"

    private nonisolated static let oneCard = ContactLinkedAddresses(
        contactAddressLists: [[work, home]]
    )
    private nonisolated static let hashWork = calculateParticipantHash(from: [work])
    private nonisolated static let hashHome = calculateParticipantHash(from: [home])
    private nonisolated static let hashCarol = calculateParticipantHash(from: [carol])

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        coreDataStack = CoreDataStack(persistentContainerForTesting: stack.persistentContainer)
        context = stack.makeMainQueueViewContext()
        migrationFlags = InMemoryMigrationFlagStore()
        inbox = LabelBuilder().inbox().build(in: context)
    }

    override func tearDown() {
        inbox = nil
        migrationFlags = nil
        context = nil
        coreDataStack = nil
        stack = nil
        super.tearDown()
    }

    // MARK: - Linking

    /// The hash of a one-to-one chat with the person, by either address, once
    /// the card links them. It is `hashHome`: that is not a rule the tests
    /// lean on, only what the fixture's addresses give.
    func testFixture_linkedHash_isTheSameFromEitherAddress() {
        for address in [Self.work, Self.home] {
            XCTAssertEqual(
                makeParticipantSetIdentity(
                    normalizedEmails: [address],
                    myAliases: [Self.me],
                    contactLinks: Self.oneCard
                ).participantHash,
                Self.hashHome
            )
        }
    }

    // Revert-check: the `unifyConversationsByContactIfNeeded` call, or the
    // `contactLinks:` argument `participantRowIdentity` passes to
    // `makeParticipantSetIdentity`. Without either, both chats keep the hash
    // of their own address and stay two rows in the list.
    func testUnify_twoAddressesOnOneContactCard_mergesTheirChatsIntoOne() async throws {
        let workChat = try seedChat(
            with: Self.work, hash: Self.hashWork, messageIDs: ["work-1", "work-2"], startingAt: 100
        )
        workChat.pinned = true
        let workChatID = workChat.id
        try seedChat(with: Self.home, hash: Self.hashHome, messageIDs: ["home-1"], startingAt: 300)
        let carolChat = try seedChat(
            with: Self.carol, hash: Self.hashCarol, messageIDs: ["carol-1"], startingAt: 50
        )
        let carolChatID = carolChat.id
        try context.save()

        let contacts = makeContacts(cards: [[Self.work, Self.home]])
        await makeService(contacts: contacts)
            .unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())

        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 2, "The person's two chats are one; nobody else's chat is touched")
        let unified = try XCTUnwrap(
            states.first { $0.id == workChatID },
            "The chat with more messages takes the other's in"
        )
        XCTAssertEqual(unified.messageIDs, ["work-1", "work-2", "home-1"])
        XCTAssertEqual(unified.participantHash, Self.hashHome)
        XCTAssertEqual(unified.participantEmails, [Self.work], "The row stays the address its chat was opened with")
        XCTAssertEqual(unified.typeRaw, ConversationType.oneToOne.rawValue)
        XCTAssertTrue(unified.pinned)
        XCTAssertNil(unified.archivedAt)
        XCTAssertEqual(unified.lastMessageDate, Date(timeIntervalSince1970: 300))

        let carolState = try XCTUnwrap(states.first { $0.id == carolChatID })
        XCTAssertEqual(carolState.participantHash, Self.hashCarol)
        XCTAssertEqual(carolState.messageIDs, ["carol-1"])

        XCTAssertEqual(contacts.appliedToConversations(), Self.oneCard)
        XCTAssertEqual(contacts.snapshot(), Self.oneCard, "The router hashes with the links the pass applied")
    }

    /// What the merge is for: after it, mail from either address is routed to
    /// the one chat. The router's lookup is by hash, so this asks it with the
    /// identity each address gives under the adopted links.
    func testUnify_afterMerging_mailFromEitherAddressFindsTheOneChat() async throws {
        let workChat = try seedChat(
            with: Self.work, hash: Self.hashWork, messageIDs: ["work-1", "work-2"], startingAt: 100
        )
        try seedChat(with: Self.home, hash: Self.hashHome, messageIDs: ["home-1"], startingAt: 300)
        try context.save()
        let workChatObjectID = workChat.objectID

        let contacts = makeContacts(cards: [[Self.work, Self.home]])
        await makeService(contacts: contacts)
            .unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())

        let manager = ConversationManager(currentUserEmail: { Self.me })
        for sender in [Self.work, Self.home] {
            let identity = makeConversationIdentity(
                from: [
                    MessageHeader(name: "From", value: sender),
                    MessageHeader(name: "To", value: Self.me)
                ],
                myAliases: [Self.me],
                contactLinks: contacts.snapshot()
            )
            let routed = try await manager.findOrCreateConversationObjectID(
                for: identity,
                in: coreDataStack.newBackgroundContext()
            )
            XCTAssertEqual(routed, workChatObjectID, sender)
        }
        XCTAssertEqual(try fetchConversationStates().count, 1, "No second chat was opened")
    }

    /// One chat that already holds both addresses (a message that copied the
    /// person's other address) was a group of two. It is one person.
    ///
    /// Revert-check: `linkedExtraRows` in `participantRowIdentity`. With the
    /// second row kept, the title and the Participants sheet show the person
    /// twice ("Morgan Vale +1").
    func testUnify_chatHoldingBothAddresses_becomesOneToOneWithOneRow() async throws {
        let chat = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: [Self.work, Self.home]))
            .withDisplayName("Morgan Vale +1")
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        chat.conversationType = .group
        addConversationParticipant(email: Self.work, displayName: "Morgan Vale", to: chat)
        addConversationParticipant(email: Self.home, displayName: "Morgan Vale", to: chat)
        try addMessage(
            id: "both-1", date: Date(timeIntervalSince1970: 100),
            from: Self.work, to: [Self.me], cc: [Self.home], in: chat
        )
        try context.save()

        await makeService(contacts: makeContacts(cards: [[Self.work, Self.home]]))
            .unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())

        let state = try XCTUnwrap(try fetchConversationStates().first)
        XCTAssertEqual(state.participantHash, Self.hashHome)
        XCTAssertEqual(state.typeRaw, ConversationType.oneToOne.rawValue)
        XCTAssertEqual(state.participantEmails, [Self.home], "The row the title already showed first is the one kept")
        XCTAssertEqual(state.displayName, "Morgan Vale")
    }

    func testUnify_linkedPersonInAGroup_mergesTheTwoGroups() async throws {
        let viaWork = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: [Self.work, Self.carol]))
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        viaWork.conversationType = .group
        addConversationParticipant(email: Self.work, to: viaWork)
        addConversationParticipant(email: Self.carol, to: viaWork)
        try addMessage(
            id: "group-work", date: Date(timeIntervalSince1970: 100),
            from: Self.work, to: [Self.me, Self.carol], in: viaWork
        )
        let viaHome = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: [Self.home, Self.carol]))
            .withLastMessageDate(Date(timeIntervalSince1970: 200))
            .visible()
            .build(in: context)
        viaHome.conversationType = .group
        addConversationParticipant(email: Self.home, to: viaHome)
        addConversationParticipant(email: Self.carol, to: viaHome)
        try addMessage(
            id: "group-home", date: Date(timeIntervalSince1970: 200),
            from: Self.home, to: [Self.me, Self.carol], in: viaHome
        )
        // Carol's own chat names no changed address and is not read at all.
        try seedChat(with: Self.carol, hash: Self.hashCarol, messageIDs: ["carol-1"], startingAt: 50)
        try context.save()

        await makeService(contacts: makeContacts(cards: [[Self.work, Self.home]]))
            .unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())

        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 2)
        let group = try XCTUnwrap(states.first { $0.messageIDs.contains("group-work") })
        XCTAssertEqual(group.messageIDs, ["group-work", "group-home"])
        XCTAssertEqual(group.participantHash, calculateParticipantHash(from: [Self.home, Self.carol]))
        XCTAssertEqual(group.typeRaw, ConversationType.group.rawValue)
    }

    /// An archived chat takes the shared hash, so mail that reopens the
    /// conversation finds it, and is merged into nothing: two archived
    /// conversations of one participant set are never merged either.
    ///
    /// Revert-check: the `.conversationsNaming` scope reading archived
    /// conversations (`fetchConversationsForParticipantHashRepair`). Under the
    /// active-only predicate the archived chat keeps a hash no mail is routed
    /// by, and its history is left behind when the person writes again.
    func testUnify_archivedChatOfTheOtherAddress_takesTheSharedHashAndStaysArchived() async throws {
        let archivedDate = Date(timeIntervalSince1970: 500)
        let archivedWorkChat = ConversationBuilder()
            .withParticipantHash(Self.hashWork)
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .archivedOn(archivedDate)
            .setHidden()
            .hasInboxMessages(false)
            .build(in: context)
        let archivedWorkChatID = archivedWorkChat.id
        addConversationParticipant(email: Self.work, to: archivedWorkChat)
        try addMessage(
            id: "old-work", date: Date(timeIntervalSince1970: 100),
            from: Self.work, to: [Self.me], labels: [], in: archivedWorkChat
        )
        try seedChat(with: Self.home, hash: Self.hashHome, messageIDs: ["home-1"], startingAt: 300)
        try context.save()
        let contacts = makeContacts(cards: [[Self.work, Self.home]])

        await makeService(contacts: contacts)
            .unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())

        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 2, "An archived chat is not merged into the active one")
        let archived = try XCTUnwrap(states.first { $0.id == archivedWorkChatID })
        XCTAssertEqual(archived.participantHash, Self.hashHome)
        XCTAssertEqual(archived.archivedAt, archivedDate)
        XCTAssertTrue(archived.hidden)
        XCTAssertEqual(archived.messageIDs, ["old-work"])
        XCTAssertEqual(contacts.appliedToConversations(), Self.oneCard)
    }

    // MARK: - When the pass does nothing

    // Revert-check: the `guard links != applied` return in
    // `unifyConversationsByContactIfNeeded`. This runs at the end of every
    // sync; without the guard each one loads the aliases and reads the store.
    func testUnify_linksAlreadyApplied_readsNothingTheSecondTime() async throws {
        try seedChat(with: Self.work, hash: Self.hashWork, messageIDs: ["work-1"], startingAt: 100)
        try seedChat(with: Self.home, hash: Self.hashHome, messageIDs: ["home-1"], startingAt: 300)
        try context.save()
        let aliasReads = CallCounter()
        let addressBook = AddressBookStub(cards: [[Self.work, Self.home]])
        let service = makeService(contacts: makeContacts(addressBook: addressBook), aliasReads: aliasReads)

        await service.unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())
        XCTAssertEqual(aliasReads.count, 1)
        XCTAssertEqual(try fetchConversationStates().count, 1)

        await service.unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())

        XCTAssertEqual(aliasReads.count, 1, "With the links applied, the pass reads nothing")
        XCTAssertEqual(addressBook.readCount, 1, "Contacts that did not change are not read again either")
    }

    /// Without Contacts access there is nothing to apply, now or later.
    func testUnify_contactsUnreadable_changesNothingAndReadsNothing() async throws {
        try seedChat(with: Self.work, hash: Self.hashWork, messageIDs: ["work-1"], startingAt: 100)
        try seedChat(with: Self.home, hash: Self.hashHome, messageIDs: ["home-1"], startingAt: 300)
        try context.save()
        let aliasReads = CallCounter()

        await makeService(contacts: makeContacts(cards: nil), aliasReads: aliasReads)
            .unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())

        XCTAssertEqual(try fetchConversationStates().count, 2)
        XCTAssertEqual(aliasReads.count, 0)
    }

    /// Before sign-in there are no aliases to hash with. The links are
    /// adopted, nothing is recorded as applied, and the next run applies them.
    func testUnify_aliasesNotYetKnown_leavesTheLinksUnappliedForTheNextRun() async throws {
        try seedChat(with: Self.work, hash: Self.hashWork, messageIDs: ["work-1"], startingAt: 100)
        try seedChat(with: Self.home, hash: Self.hashHome, messageIDs: ["home-1"], startingAt: 300)
        try context.save()
        let contacts = makeContacts(cards: [[Self.work, Self.home]])

        await makeService(contacts: contacts, aliases: [])
            .unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())

        XCTAssertEqual(try fetchConversationStates().count, 2)
        XCTAssertTrue(contacts.appliedToConversations().isEmpty)

        await makeService(contacts: contacts)
            .unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())

        XCTAssertEqual(try fetchConversationStates().count, 1)
    }

    // MARK: - Protected conversations

    /// The shape a send in flight really gives: the anchored chat is one of
    /// the two that are to become one. It takes the shared hash where it is,
    /// so the send's echo and the person's next mail still find a chat that
    /// carries the router's hash, and it keeps its messages and is merged
    /// with nothing until the send is done.
    ///
    /// Revert-check: the `correctHashesOfProtectedActiveConversations` test
    /// after the loop in `fixAndMergeIncorrectParticipantHashes`. Without it
    /// the pass is recorded as applied with the two chats still apart.
    func testUnify_chatAnchoringAPendingSend_takesTheHashAndIsMergedOnceReleased() async throws {
        let workChat = try seedChat(
            with: Self.work, hash: Self.hashWork, messageIDs: ["work-1"], startingAt: 100
        )
        let workChatID = workChat.id
        try seedChat(with: Self.home, hash: Self.hashHome, messageIDs: ["home-1", "home-2"], startingAt: 300)
        let record = context.insertTestObject(OutboundSendMutationRecord.self)
        record.id = UUID().uuidString
        record.createdAt = Date()
        record.conversationId = workChatID
        try context.save()
        let contacts = makeContacts(cards: [[Self.work, Self.home]])
        let service = makeService(contacts: contacts)

        await service.unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())

        var states = try fetchConversationStates()
        XCTAssertEqual(states.count, 2)
        let anchored = try XCTUnwrap(states.first { $0.id == workChatID })
        XCTAssertEqual(anchored.participantHash, Self.hashHome, "A send's anchor takes the shared hash in place")
        XCTAssertEqual(anchored.messageIDs, ["work-1"], "and keeps its messages: it is merged with nothing")
        XCTAssertEqual(anchored.participantEmails, [Self.work])
        XCTAssertTrue(
            contacts.appliedToConversations().isEmpty,
            "Not applied yet: the next cleanup has to come back to this chat"
        )

        context.delete(record)
        try context.save()
        await service.unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())

        states = try fetchConversationStates()
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.first?.messageIDs, ["work-1", "home-1", "home-2"])
        XCTAssertEqual(states.first?.participantHash, Self.hashHome)
        XCTAssertEqual(contacts.appliedToConversations(), Self.oneCard)
    }

    /// An anchored chat that holds both of the person's addresses takes the
    /// shared hash, and nothing else about it is written: a send in flight
    /// keeps the rows it was addressed from.
    ///
    /// Revert-check: `needsRepair(of:)` setting
    /// `isBlockedByProtectedConversation` in
    /// `fixAndMergeIncorrectParticipantHashes`. Reported as completed, the
    /// links are recorded as applied, the pass does not come back once the
    /// send is done, and the chat goes on showing the person once for each
    /// address.
    func testUnify_anchoredChatHoldingBothAddresses_keepsItsRowsUntilReleased() async throws {
        let chat = ConversationBuilder()
            .withParticipantHash(calculateParticipantHash(from: [Self.work, Self.home]))
            .withLastMessageDate(Date(timeIntervalSince1970: 100))
            .visible()
            .build(in: context)
        chat.conversationType = .group
        addConversationParticipant(email: Self.work, to: chat)
        addConversationParticipant(email: Self.home, to: chat)
        try addMessage(
            id: "both-1", date: Date(timeIntervalSince1970: 100),
            from: Self.work, to: [Self.me], cc: [Self.home], in: chat
        )
        let record = context.insertTestObject(OutboundSendMutationRecord.self)
        record.id = UUID().uuidString
        record.createdAt = Date()
        record.conversationId = chat.id
        try context.save()
        let contacts = makeContacts(cards: [[Self.work, Self.home]])
        let service = makeService(contacts: contacts)

        await service.unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())

        var state = try XCTUnwrap(try fetchConversationStates().first)
        XCTAssertEqual(state.participantHash, Self.hashHome)
        XCTAssertEqual(state.participantEmails, [Self.work, Self.home])
        XCTAssertEqual(state.typeRaw, ConversationType.group.rawValue)
        XCTAssertTrue(contacts.appliedToConversations().isEmpty)

        context.delete(record)
        try context.save()
        await service.unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())

        state = try XCTUnwrap(try fetchConversationStates().first)
        XCTAssertEqual(state.participantHash, Self.hashHome)
        XCTAssertEqual(state.participantEmails, [Self.home])
        XCTAssertEqual(state.typeRaw, ConversationType.oneToOne.rawValue)
        XCTAssertEqual(contacts.appliedToConversations(), Self.oneCard)
    }

    /// A deferred chat-preview retry finds its conversation again through
    /// the hash it recorded, so this is the one anchor that keeps its old
    /// hash, as it does in maintenance.
    ///
    /// Revert-check: the `!isAnchoredByChatPreviewRetry` condition on the
    /// in-place write in `fixAndMergeIncorrectParticipantHashes`. Given the
    /// shared hash, a conversation merged away before its retry leaves the
    /// retry looking for rows under a hash nothing carries.
    func testUnify_chatAnchoredByAChatPreviewRetry_keepsItsHashUntilTheRetryHasRun() async throws {
        let workChat = try seedChat(
            with: Self.work, hash: Self.hashWork, messageIDs: ["work-1"], startingAt: 100
        )
        try context.save()
        let checkpointKey = ConversationLaunchRepairCoordinator.chatPreviewRepairCheckpointKey
        migrationFlags.setString(
            ChatPreviewRepair.Checkpoint(
                deferredConversations: [ChatPreviewRepair.DeferredConversation(workChat)]
            ).encoded,
            forKey: checkpointKey
        )
        let contacts = makeContacts(cards: [[Self.work, Self.home]])
        let service = makeService(contacts: contacts)

        await service.unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())

        XCTAssertEqual(try fetchConversationStates().first?.participantHash, Self.hashWork)
        XCTAssertTrue(contacts.appliedToConversations().isEmpty)

        migrationFlags.setString(nil, forKey: checkpointKey)
        await service.unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())

        XCTAssertEqual(try fetchConversationStates().first?.participantHash, Self.hashHome)
        XCTAssertEqual(contacts.appliedToConversations(), Self.oneCard)
    }

    /// Two anchored chats that come to share a hash both take it, and neither
    /// can be merged into the other while both are anchored.
    ///
    /// Revert-check: the `insert(correctHash).inserted` test for an anchored
    /// conversation in `fixAndMergeIncorrectParticipantHashes`. Each chat
    /// alone has nothing left to write, so without it the links are recorded
    /// as applied and the pass never comes back to merge the two.
    func testUnify_twoAnchoredChatsOfOnePerson_areMergedOnceReleased() async throws {
        let workChat = try seedChat(
            with: Self.work, hash: Self.hashWork, messageIDs: ["work-1"], startingAt: 100
        )
        let homeChat = try seedChat(
            with: Self.home, hash: Self.hashHome, messageIDs: ["home-1"], startingAt: 300
        )
        let drafts = [workChat, homeChat].map { chat -> ChatReplyDraft in
            let draft = context.insertTestObject(ChatReplyDraft.self)
            draft.conversationId = chat.id
            return draft
        }
        try context.save()
        let contacts = makeContacts(cards: [[Self.work, Self.home]])
        let service = makeService(contacts: contacts)

        await service.unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())

        var states = try fetchConversationStates()
        XCTAssertEqual(states.map(\.participantHash), [Self.hashHome, Self.hashHome])
        XCTAssertTrue(contacts.appliedToConversations().isEmpty)

        for draft in drafts {
            context.delete(draft)
        }
        try context.save()
        await service.unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())

        states = try fetchConversationStates()
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.first?.messageIDs, ["work-1", "home-1"])
        XCTAssertEqual(contacts.appliedToConversations(), Self.oneCard)
    }

    /// The anchored chat here already carries the shared hash (its address is
    /// the one that stands for the person), so the pass has nothing to write
    /// to it. It is still not done: the other chat came to share that hash and
    /// could not be merged with an anchor.
    ///
    /// Revert-check: the `correctHashesOfProtectedActiveConversations` test
    /// after the loop in `fixAndMergeIncorrectParticipantHashes`.
    func testUnify_anchoredChatAlreadyOnTheSharedHash_isNotRecordedAsApplied() async throws {
        let homeChat = try seedChat(
            with: Self.home, hash: Self.hashHome, messageIDs: ["home-1"], startingAt: 300
        )
        let record = context.insertTestObject(OutboundSendMutationRecord.self)
        record.id = UUID().uuidString
        record.createdAt = Date()
        record.conversationId = homeChat.id
        try seedChat(with: Self.work, hash: Self.hashWork, messageIDs: ["work-1"], startingAt: 100)
        try context.save()
        let contacts = makeContacts(cards: [[Self.work, Self.home]])
        let service = makeService(contacts: contacts)

        await service.unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())

        var states = try fetchConversationStates()
        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(states.map(\.participantHash), [Self.hashHome, Self.hashHome])
        XCTAssertTrue(contacts.appliedToConversations().isEmpty)

        context.delete(record)
        try context.save()
        await service.unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())

        states = try fetchConversationStates()
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.first?.messageIDs, ["work-1", "home-1"])
        XCTAssertEqual(contacts.appliedToConversations(), Self.oneCard)
    }

    /// A saved reply draft anchors its chat for as long as the draft is kept,
    /// which can be weeks. The router hashes with the adopted links from the
    /// moment they are adopted, so an anchored chat left on the hash of its
    /// own address stops receiving the person's mail: the next message from
    /// that very address opens a second chat beside it.
    ///
    /// Revert-check: the `conv.participantHash = correctHash` write for an
    /// anchored conversation in `fixAndMergeIncorrectParticipantHashes`.
    /// Without it the chat keeps `hashWork`, the router asks for `hashHome`,
    /// and a second chat is made.
    func testUnify_chatHoldingASavedReplyDraft_takesTheSharedHashInPlaceSoItsMailStillFindsIt() async throws {
        let workChat = try seedChat(
            with: Self.work, hash: Self.hashWork, messageIDs: ["work-1"], startingAt: 100
        )
        let draft = context.insertTestObject(ChatReplyDraft.self)
        draft.conversationId = workChat.id
        try context.save()
        let workChatObjectID = workChat.objectID
        let contacts = makeContacts(cards: [[Self.work, Self.home]])

        await makeService(contacts: contacts)
            .unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())

        let anchored = try XCTUnwrap(try fetchConversationStates().first)
        XCTAssertEqual(anchored.participantHash, Self.hashHome)
        XCTAssertEqual(anchored.participantEmails, [Self.work], "Its rows are not touched while it is anchored")
        XCTAssertEqual(anchored.messageIDs, ["work-1"])
        XCTAssertEqual(
            contacts.appliedToConversations(), Self.oneCard,
            "Nothing is left to do for it: no row to fold and no chat to merge"
        )

        let manager = ConversationManager(currentUserEmail: { Self.me })
        for sender in [Self.work, Self.home] {
            let identity = makeConversationIdentity(
                from: [
                    MessageHeader(name: "From", value: sender),
                    MessageHeader(name: "To", value: Self.me)
                ],
                myAliases: [Self.me],
                contactLinks: contacts.snapshot()
            )
            let routed = try await manager.findOrCreateConversationObjectID(
                for: identity,
                in: coreDataStack.newBackgroundContext()
            )
            XCTAssertEqual(routed, workChatObjectID, sender)
        }
        XCTAssertEqual(try fetchConversationStates().count, 1, "No second chat was opened beside the draft's")
    }

    // MARK: - Unlinking

    /// When the card stops listing an address, the chat keeps the messages it
    /// has: this pass moves conversations, not messages. The chat goes back to
    /// the hash of its own row, so mail from the other address opens a chat of
    /// its own again.
    func testUnify_cardStopsLinkingTheAddresses_keepsTheChatAndReturnsItToItsOwnHash() async throws {
        let workChat = try seedChat(
            with: Self.work, hash: Self.hashWork, messageIDs: ["work-1", "work-2"], startingAt: 100
        )
        let workChatID = workChat.id
        try seedChat(with: Self.home, hash: Self.hashHome, messageIDs: ["home-1"], startingAt: 300)
        try context.save()
        let addressBook = AddressBookStub(cards: [[Self.work, Self.home]])
        let contacts = makeContacts(addressBook: addressBook)
        let service = makeService(contacts: contacts)
        await service.unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())
        XCTAssertEqual(try fetchConversationStates().first?.participantHash, Self.hashHome)

        addressBook.cards = [[Self.work]]
        contacts.markContactsChanged()
        await service.unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())

        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.first?.id, workChatID)
        XCTAssertEqual(states.first?.participantHash, Self.hashWork)
        XCTAssertEqual(states.first?.messageIDs, ["work-1", "work-2", "home-1"])
        XCTAssertTrue(contacts.appliedToConversations().isEmpty)
        XCTAssertTrue(contacts.snapshot().isEmpty)
    }

    /// Contacts access the user turns off unlinks as an edited card does, and
    /// with no change in Contacts to report it: the next cleanup gives the
    /// chat its own hash back and nothing of the links is kept, applied map
    /// included.
    ///
    /// Revert-check: the `access == .withdrawn` branch at the top of
    /// `ContactLinkedAddressStore.refreshIfNeeded`. Without it the pass sees
    /// the adopted links unchanged and returns at its first comparison.
    func testUnify_contactsAccessWithdrawn_returnsTheChatToItsOwnHashAndKeepsNoLinks() async throws {
        let workChat = try seedChat(
            with: Self.work, hash: Self.hashWork, messageIDs: ["work-1", "work-2"], startingAt: 100
        )
        let workChatID = workChat.id
        try seedChat(with: Self.home, hash: Self.hashHome, messageIDs: ["home-1"], startingAt: 300)
        try context.save()
        let addressBook = AddressBookStub(cards: [[Self.work, Self.home]])
        let contacts = makeContacts(addressBook: addressBook)
        let service = makeService(contacts: contacts)
        await service.unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())
        XCTAssertEqual(contacts.appliedToConversations(), Self.oneCard)

        addressBook.authorization = .denied
        await service.unifyConversationsByContactIfNeeded(in: coreDataStack.newBackgroundContext())

        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.first?.id, workChatID)
        XCTAssertEqual(states.first?.participantHash, Self.hashWork)
        XCTAssertEqual(states.first?.messageIDs, ["work-1", "work-2", "home-1"], "What was merged stays merged")
        XCTAssertTrue(contacts.snapshot().isEmpty)
        XCTAssertTrue(contacts.appliedToConversations().isEmpty)
        XCTAssertEqual(addressBook.readCount, 1, "Nothing is read without access")
    }

    // MARK: - Maintenance

    /// The 6-hour hash repair hashes with the adopted links as well, so it
    /// never undoes what the pass above did, and it merges active chats the
    /// scoped pass had to leave.
    ///
    /// Revert-check: `contactLinkStore.snapshot()` in
    /// `fixAndMergeIncorrectParticipantHashes`. Hashing rows with nothing
    /// linked, maintenance gives the unified chat back the hash of its row's
    /// own address, and the next mail from the other address forks it.
    func testMaintenanceHashRepair_withAdoptedLinks_keepsAndCompletesTheUnification() async throws {
        let unified = try seedChat(
            with: Self.work, hash: Self.hashHome, messageIDs: ["work-1", "work-2"], startingAt: 100
        )
        let unifiedID = unified.id
        try seedChat(with: Self.home, hash: Self.hashHome, messageIDs: ["home-1"], startingAt: 300)
        try context.save()
        let contacts = makeContacts(cards: [[Self.work, Self.home]])
        contacts.refreshIfNeeded()

        let outcome = await makeService(contacts: contacts)
            .fixAndMergeIncorrectParticipantHashes(in: coreDataStack.newBackgroundContext())

        XCTAssertEqual(outcome, .completed)
        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.first?.id, unifiedID)
        XCTAssertEqual(states.first?.participantHash, Self.hashHome)
        XCTAssertEqual(states.first?.messageIDs, ["work-1", "work-2", "home-1"])
    }

    // MARK: - Fixture Helpers

    private func makeContacts(cards: [[String]]?) -> ContactLinkedAddressStore {
        makeContacts(addressBook: AddressBookStub(cards: cards))
    }

    /// A store of the test's own: no defaults, a notification center nothing
    /// else posts to, and the stub for an address book and its authorization.
    private func makeContacts(addressBook: AddressBookStub) -> ContactLinkedAddressStore {
        ContactLinkedAddressStore(
            defaults: nil,
            notificationCenter: NotificationCenter(),
            contactsAuthorizationStatus: { addressBook.authorization },
            loadContactAddressLists: { addressBook.read() }
        )
    }

    private func makeService(
        contacts: ContactLinkedAddressStore,
        aliases: Set<String> = [ContactUnificationCleanupTests.me],
        aliasReads: CallCounter? = nil
    ) -> DataCleanupService {
        DataCleanupService(
            coreDataStack: coreDataStack,
            conversationManager: ConversationManager(
                currentUserEmail: { Self.me },
                contactLinks: { contacts.snapshot() }
            ),
            migrationFlags: migrationFlags,
            identityAliasProvider: { _ in
                aliasReads?.increment()
                return aliases
            },
            contactLinkStore: contacts
        )
    }

    /// An active one-to-one chat with `address`: one participant row, and
    /// inbox messages from that address a second apart.
    @discardableResult
    private func seedChat(
        with address: String,
        hash: String,
        messageIDs: [String],
        startingAt start: TimeInterval
    ) throws -> Conversation {
        let chat = ConversationBuilder()
            .withParticipantHash(hash)
            .withLastMessageDate(Date(timeIntervalSince1970: start + TimeInterval(messageIDs.count - 1)))
            .visible()
            .build(in: context)
        addConversationParticipant(email: address, to: chat)
        for (index, id) in messageIDs.enumerated() {
            try addMessage(
                id: id, date: Date(timeIntervalSince1970: start + TimeInterval(index)),
                from: address, to: [Self.me], in: chat
            )
        }
        return chat
    }

    @discardableResult
    private func addMessage(
        id: String,
        date: Date,
        from: String,
        to: [String],
        cc: [String] = [],
        labels: [Label]? = nil,
        in conversation: Conversation
    ) throws -> Message {
        let message = MessageBuilder()
            .withId(id)
            .withThreadId("thread-\(id)")
            .withDate(date)
            .withSender(email: from)
            .inConversation(conversation)
            .build(in: context)

        _ = try MessageParticipantFactory.create(from: from, kind: .from, for: message, in: context)
        for recipient in to {
            _ = try MessageParticipantFactory.create(from: recipient, kind: .to, for: message, in: context)
        }
        for recipient in cc {
            _ = try MessageParticipantFactory.create(from: recipient, kind: .cc, for: message, in: context)
        }
        // In the inbox unless the test says otherwise: a merge recomputes the
        // winner's rollup, and a chat with no inbox mail is archived by it.
        for label in labels ?? [inbox] {
            message.addToLabels(label)
        }
        return message
    }

    private func addConversationParticipant(
        email: String,
        displayName: String? = nil,
        to conversation: Conversation
    ) {
        let person = PersonBuilder()
            .withEmail(email)
            .withDisplayName(displayName)
            .build(in: context)
        let participant = context.insertTestObject(ConversationParticipant.self)
        participant.id = UUID()
        participant.role = ParticipantRole.normal.rawValue
        participant.person = person
        participant.conversation = conversation
    }

    // MARK: - State Assertions

    private struct ConversationState {
        let id: UUID
        let participantHash: String?
        let displayName: String?
        let archivedAt: Date?
        let lastMessageDate: Date?
        let messageIDs: Set<String>
        let participantEmails: Set<String>
        let typeRaw: String
        let pinned: Bool
        let hidden: Bool
    }

    /// Snapshots every conversation from a fresh context so assertions observe
    /// persisted store state, never stale objects registered with the fixture
    /// context (which does not auto-merge the pass's saves).
    private func fetchConversationStates() throws -> [ConversationState] {
        let fetchContext = stack.newBackgroundContext()
        return try fetchContext.performAndWait {
            let request = Conversation.fetchRequest()
            request.relationshipKeyPathsForPrefetching = [
                "messages", "participants", "participants.person"
            ]
            return try fetchContext.fetch(request).map { conversation in
                ConversationState(
                    id: conversation.id,
                    participantHash: conversation.participantHash,
                    displayName: conversation.displayName,
                    archivedAt: conversation.archivedAt,
                    lastMessageDate: conversation.lastMessageDate,
                    messageIDs: Set((conversation.messages ?? []).map(\.id)),
                    participantEmails: Set(
                        (conversation.participants ?? []).compactMap { $0.person?.email }
                    ),
                    typeRaw: conversation.type,
                    pinned: conversation.pinned,
                    hidden: conversation.hidden
                )
            }
        }
    }
}

/// Counts calls made from a `@Sendable` closure.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int {
        lock.withLock { storedCount }
    }

    func increment() {
        lock.withLock { storedCount += 1 }
    }
}
