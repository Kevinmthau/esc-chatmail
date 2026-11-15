import XCTest
import CoreData
@testable import esc_chatmail

/// Every fixture, save, reset, and assertion goes through the suite's
/// `viewContext`, a main-queue context from
/// `TestCoreDataStack.makeMainQueueViewContext()`, never
/// `coreDataStack.viewContext`, which is private-queue.
/// `OutboundReplyContextBuilder` is `@MainActor` and fetches from its context
/// directly, which is on-queue only for a main-queue context. See that helper
/// for what the private-queue shape races.
///
/// HONEST SCOPE: no test here can reproduce that race on demand. With
/// `-com.apple.CoreData.ConcurrencyDebug 1` the old shape traps and this shape
/// runs clean.
@MainActor
final class OutboundReplyContextBuilderTests: XCTestCase {
    private var coreDataStack: TestCoreDataStack!
    private var viewContext: NSManagedObjectContext!
    private var htmlContentHandler: HTMLContentHandler!

    override func setUp() {
        super.setUp()
        coreDataStack = TestCoreDataStack()
        viewContext = coreDataStack.makeMainQueueViewContext()
        htmlContentHandler = HTMLContentHandler()
    }

    override func tearDown() {
        htmlContentHandler = nil
        viewContext = nil
        coreDataStack = nil
        super.tearDown()
    }

    func testBuild_createsStableReplyRequestContextAndConversationAnchor() throws {
        let context: NSManagedObjectContext = viewContext
        let conversation = ConversationBuilder()
            .visible()
            .recentlyActive()
            .build(in: context)
        let replyingTo = MessageBuilder()
            .withId("message-1")
            .inConversation(conversation)
            .build(in: context)
        try context.obtainPermanentIDs(for: [conversation, replyingTo])
        let builder = makeBuilder()
        let conversationReference = ConversationReference(objectID: conversation.objectID)

        let replyContext = builder.build(
            conversationObjectID: conversation.objectID,
            replyingToMessageObjectID: replyingTo.objectID,
            optimisticConversation: .existingConversation(conversationReference)
        )

        XCTAssertEqual(replyContext.conversationObjectID, conversation.objectID)
        XCTAssertEqual(replyContext.replyingToMessageObjectID, replyingTo.objectID)
        XCTAssertEqual(replyContext.optimisticConversation?.existingConversationReference, conversationReference)
    }

    func testBuildReplyMetadata_readsReplyMetadataFromManagedObjects() async throws {
        let context: NSManagedObjectContext = viewContext
        let conversation = makeReplyConversation(in: context, friendEmail: "friend@example.com")
        let replyingTo = MessageBuilder()
            .withId("message-1")
            .withThreadId("thread-123")
            .withSubject("Original Subject")
            .withSender(email: "friend@example.com", name: "Friend")
            .withBody("Original body")
            .inConversation(conversation)
            .build(in: context)
        try context.obtainPermanentIDs(for: [conversation, replyingTo])
        replyingTo.messageId = "<message-1@example.com>"
        replyingTo.references = "<older@example.com>"
        addMessageParticipant(email: "different-target@example.com", kind: .from, to: replyingTo)
        addMessageParticipant(email: "me@example.com", kind: .to, to: replyingTo)
        _ = htmlContentHandler.saveHTML(
            "<html><body><p>Original <strong>HTML</strong></p></body></html>",
            for: replyingTo.id
        )

        let metadata = try await makeBuilder().buildReplyMetadata(
            .init(
                conversationObjectID: conversation.objectID,
                replyingToMessageObjectID: replyingTo.objectID,
                optimisticConversation: .existingConversation(
                    ConversationReference(objectID: conversation.objectID)
                )
            )
        )

        XCTAssertEqual(metadata.recipientEmails, ["friend@example.com"])
        XCTAssertEqual(metadata.subject, "Re: Original Subject")
        XCTAssertEqual(metadata.threadId, "thread-123")
        XCTAssertEqual(metadata.inReplyTo, "<message-1@example.com>")
        XCTAssertEqual(metadata.references, ["<older@example.com>", "<message-1@example.com>"])
        XCTAssertEqual(metadata.originalMessage?.senderName, "Friend")
        XCTAssertEqual(metadata.originalMessage?.senderEmail, "friend@example.com")
        XCTAssertEqual(metadata.originalMessage?.body, "Original body")
        XCTAssertNil(metadata.originalMessage?.originalHTML)
        let resolvedOriginal = await metadata.originalMessage?.resolvingOriginalHTML()
        XCTAssertTrue(resolvedOriginal?.originalHTML?.contains("Original <strong>HTML</strong>") == true)
    }

    func testBuildReplyMetadata_selfAliasesFallbackRequiresNonListParticipants() throws {
        // Revert-check: ReplyMetadataBuilder's self-only fallback is required
        // for legacy self aliases, but must not invent recipients for empty/list chats.
        let builder = ReplyMetadataBuilder(authSession: makeTestAuthSession(userEmail: "me@example.com"))
        let cases: [(participants: [String], isList: Bool, expected: [String])] = [
            (["legacy-self@example.com"], false, ["me@example.com"]),
            (["alias@example.com"], false, ["me@example.com"]),
            ([], false, []),
            ([" "], false, []),
            (["me@example.com"], true, []),
            (["me@example.com", "friend@example.com"], false, ["friend@example.com"])
        ]
        for testCase in cases {
            let metadata = try builder.buildReplyMetadata(
                conversation: .init(
                    participantEmails: testCase.participants,
                    isListConversation: testCase.isList,
                    latestThreadId: "thread",
                    latestThreadParticipantEvidence: ReplyParticipantEvidence(
                        emails: testCase.participants,
                        hasAddressableRecipientRow: !testCase.participants.isEmpty,
                        isComplete: true
                    )
                ),
                replyingTo: nil,
                sendAsAliases: sendAsAliases,
                userAliases: ["legacy-self@example.com"]
            )
            XCTAssertEqual(metadata.recipientEmails, testCase.expected)
        }
    }

    /// A chat that counts a person's two addresses as one participant has one
    /// row for them. The reply goes to the address the latest message used.
    ///
    /// Revert-check: the `ReplyLinkedAddressPolicy.recipients` call in
    /// `ReplyMetadataBuilder.buildReplyMetadata`. With the rows used as they
    /// are, the reply goes to the address the person wrote from first.
    func testBuildReplyMetadata_linkedParticipantWroteFromOtherAddress_repliesToThatAddress() throws {
        let work = "morgan@corp.example"
        let home = "m.vale@mail.example"
        let builder = ReplyMetadataBuilder(authSession: makeTestAuthSession(userEmail: "me@example.com"))
        let latestMessage = ReplyTargetSnapshot(
            participantEmails: [home, "me@example.com"],
            subject: "Dinner",
            threadId: "thread-home",
            messageId: nil,
            references: [],
            deliveredToAddress: nil,
            replyFromAddress: nil,
            originalMessage: QuotedMessage(
                senderName: "Morgan",
                senderEmail: home,
                date: .distantPast,
                body: nil
            )
        )
        let conversation = ReplyConversationSnapshot(
            participantEmails: [work],
            latestThreadId: "thread-home",
            latestReplyTarget: latestMessage
        )

        let linked = try builder.buildReplyMetadata(
            conversation: conversation,
            replyingTo: nil,
            sendAsAliases: sendAsAliases,
            contactLinks: ContactLinkedAddresses(contactAddressLists: [[work, home]])
        )
        XCTAssertEqual(linked.recipientEmails, [home])
        XCTAssertEqual(linked.threadId, "thread-home")

        // Nothing linked: the row's address, as before.
        let unlinked = try builder.buildReplyMetadata(
            conversation: conversation,
            replyingTo: nil,
            sendAsAliases: sendAsAliases,
            contactLinks: .none
        )
        XCTAssertEqual(unlinked.recipientEmails, [work])
    }

    /// A chat merged while a contact card linked two addresses keeps both
    /// people's mail once the card stops linking them, and has a row for one
    /// of them only. A reply to the other person's message goes to that
    /// person, read here from the managed objects a sync leaves.
    ///
    /// Revert-check: the `recipientsOverrulingRows` branch in
    /// `ReplyMetadataBuilder.buildReplyMetadata`. Without it the reply, and
    /// the message it quotes, go to the row's person, who was never on it.
    func testBuildReplyMetadata_messageOfSomeoneTheRowsDoNotName_repliesToThePeopleOnTheMessage() async throws {
        let conversation = makeReplyConversation(in: viewContext, friendEmail: "alex@example.com")
        let fromSam = MessageBuilder()
            .withId("from-sam")
            .withThreadId("sam-thread")
            .withDate(Date(timeIntervalSince1970: 200))
            .withSender(email: "sam@example.com", name: "Sam")
            .inConversation(conversation)
            .build(in: viewContext)
        addMessageParticipant(email: "sam@example.com", kind: .from, to: fromSam)
        addMessageParticipant(email: "me@example.com", kind: .to, to: fromSam)
        let toSam = MessageBuilder()
            .withId("to-sam")
            .withThreadId("sam-thread")
            .withDate(Date(timeIntervalSince1970: 100))
            .withSender(email: "me@example.com", name: "Me")
            .fromMe()
            .inConversation(conversation)
            .build(in: viewContext)
        addMessageParticipant(email: "me@example.com", kind: .from, to: toSam)
        addMessageParticipant(email: "sam@example.com", kind: .to, to: toSam)
        try viewContext.obtainPermanentIDs(for: [conversation, fromSam, toSam])

        // The latest message, a chosen one, and one the user sent themself.
        for target in [nil, fromSam.objectID, toSam.objectID] {
            let metadata = try await makeBuilder().buildReplyMetadata(.init(
                conversationObjectID: conversation.objectID,
                replyingToMessageObjectID: target,
                optimisticConversation: nil
            ))
            XCTAssertEqual(metadata.recipientEmails, ["sam@example.com"])
            XCTAssertEqual(metadata.threadId, "sam-thread")
        }
    }

    /// The rule above, shape by shape, on snapshots. Rows that keep both
    /// promises to the message answer for it, as they always have.
    func testBuildReplyMetadata_rowsOverruledOnlyWhereTheyBreakAPromiseToTheMessage() throws {
        let builder = ReplyMetadataBuilder(authSession: makeTestAuthSession(userEmail: "me@example.com"))
        func recipients(rows: [String], message: [String], from sender: String) throws -> [String] {
            try builder.buildReplyMetadata(
                conversation: ReplyConversationSnapshot(participantEmails: rows, latestThreadId: "thread"),
                replyingTo: makeReplyTarget(
                    participants: message,
                    sender: sender,
                    evidence: ReplyParticipantEvidence(
                        emails: message, hasAddressableRecipientRow: true, isComplete: true
                    )
                ),
                sendAsAliases: sendAsAliases,
                contactLinks: .none
            ).recipientEmails
        }
        let alex = "alex@example.com", sam = "sam@example.com", carol = "carol@example.com"
        let me = "me@example.com"

        // A row's person is not on the message.
        XCTAssertEqual(try recipients(rows: [alex], message: [sam, me], from: sam), [sam])
        XCTAssertEqual(try recipients(rows: [alex, carol], message: [carol, me, sam], from: carol), [carol, sam])
        // Every row is on the message, but its author is nobody's row.
        XCTAssertEqual(try recipients(rows: [alex], message: [sam, me, alex], from: sam), [sam, alex])

        // Promises kept: the rows answer, and add nobody.
        XCTAssertEqual(try recipients(rows: [alex], message: [alex, me], from: alex), [alex])
        XCTAssertEqual(try recipients(rows: [alex], message: [alex, me, sam], from: alex), [alex])
        XCTAssertEqual(try recipients(rows: [alex], message: [me, alex, sam], from: me), [alex])
    }

    /// A message whose own rows are not known to name everyone on it is no
    /// ground for overruling the conversation.
    ///
    /// Revert-check: the `evidence.namesEveryParticipant` guard in
    /// `ReplyMetadataBuilder.recipientsOverrulingRows`, and each of its two
    /// terms. A row set that holds only a sender (older persistence) would
    /// drop every other participant of a group from the reply.
    func testBuildReplyMetadata_messageNotFullyKnown_keepsTheRows() throws {
        let builder = ReplyMetadataBuilder(authSession: makeTestAuthSession(userEmail: "me@example.com"))
        let rows = ["alex@example.com", "carol@example.com"]
        let evidenceCases: [ReplyParticipantEvidence?] = [
            nil,
            ReplyParticipantEvidence(
                emails: ["sam@example.com"], hasAddressableRecipientRow: false, isComplete: true
            ),
            ReplyParticipantEvidence(
                emails: ["sam@example.com", "me@example.com"], hasAddressableRecipientRow: true, isComplete: false
            )
        ]

        for evidence in evidenceCases {
            let metadata = try builder.buildReplyMetadata(
                conversation: ReplyConversationSnapshot(participantEmails: rows, latestThreadId: "thread"),
                replyingTo: makeReplyTarget(
                    participants: ["sam@example.com", "me@example.com"],
                    sender: "sam@example.com",
                    evidence: evidence
                ),
                sendAsAliases: sendAsAliases,
                contactLinks: .none
            )
            XCTAssertEqual(metadata.recipientEmails, rows)
        }
    }

    /// A conversation with no usable row still fails closed: the rule never
    /// supplies recipients where the rows had none.
    ///
    /// Revert-check: the `!conversationRecipients.isEmpty` guard in
    /// `ReplyMetadataBuilder.recipientsOverrulingRows`.
    func testBuildReplyMetadata_conversationWithNoUsableRow_isGivenNoRecipientsByTheMessage() throws {
        let builder = ReplyMetadataBuilder(authSession: makeTestAuthSession(userEmail: "me@example.com"))

        let metadata = try builder.buildReplyMetadata(
            conversation: ReplyConversationSnapshot(participantEmails: ["me@example.com"], latestThreadId: "thread"),
            replyingTo: makeReplyTarget(
                participants: ["sam@example.com", "me@example.com"],
                sender: "sam@example.com",
                evidence: ReplyParticipantEvidence(
                    emails: ["sam@example.com", "me@example.com"],
                    hasAddressableRecipientRow: true,
                    isComplete: true
                )
            ),
            sendAsAliases: sendAsAliases,
            contactLinks: .none
        )

        XCTAssertEqual(metadata.recipientEmails, [])
    }

    private func makeReplyTarget(
        participants: [String],
        sender: String,
        evidence: ReplyParticipantEvidence?
    ) -> ReplyTargetSnapshot {
        ReplyTargetSnapshot(
            participantEmails: participants,
            subject: "Dinner",
            threadId: "thread",
            messageId: nil,
            references: [],
            deliveredToAddress: nil,
            replyFromAddress: nil,
            originalMessage: QuotedMessage(senderName: nil, senderEmail: sender, date: .distantPast, body: nil),
            participantEvidence: evidence
        )
    }

    func testBuildReplyMetadata_targetNeverBorrowsSelfEvidenceFromConversationAnchor() throws {
        let builder = ReplyMetadataBuilder(
            authSession: makeTestAuthSession(userEmail: "me@example.com")
        )
        let conversation = ReplyConversationSnapshot(
            participantEmails: ["me@example.com"],
            latestThreadId: "conversation-thread",
            latestThreadParticipantEvidence: ReplyParticipantEvidence(
                emails: ["me@example.com"],
                hasAddressableRecipientRow: true,
                isComplete: true
            )
        )
        let targetEvidenceCases: [ReplyParticipantEvidence?] = [
            nil,
            ReplyParticipantEvidence(
                emails: ["friend@example.com"],
                hasAddressableRecipientRow: false,
                isComplete: false
            )
        ]

        for participantEvidence in targetEvidenceCases {
            let metadata = try builder.buildReplyMetadata(
                conversation: conversation,
                replyingTo: ReplyTargetSnapshot(
                    participantEmails: [],
                    subject: "External reply",
                    threadId: "target-thread",
                    messageId: nil,
                    references: [],
                    deliveredToAddress: nil,
                    replyFromAddress: nil,
                    originalMessage: QuotedMessage(
                        senderName: "Friend",
                        senderEmail: "friend@example.com",
                        date: .distantPast,
                        body: nil
                    ),
                    participantEvidence: participantEvidence
                ),
                sendAsAliases: sendAsAliases
            )

            XCTAssertEqual(metadata.threadId, "target-thread")
            XCTAssertEqual(metadata.recipientEmails, [])
        }
    }

    func testBuildReplyMetadata_withoutTargetUsesAffirmedSelfOnlyThreadAnchor() async throws {
        let context: NSManagedObjectContext = viewContext
        let conversation = makeReplyConversation(in: context, friendEmail: "ME@example.com")
        let note = MessageBuilder()
            .withId("self-note")
            .withThreadId("self-thread")
            .withSender(email: "me@example.com", name: "Me")
            .fromMe()
            .inConversation(conversation)
            .build(in: context)
        addMessageParticipant(email: "me@example.com", kind: .from, to: note)
        addMessageParticipant(email: "me@example.com", kind: .to, to: note)
        try context.obtainPermanentIDs(for: [conversation, note])

        let metadata = try await makeBuilder().buildReplyMetadata(
            .init(
                conversationObjectID: conversation.objectID,
                replyingToMessageObjectID: nil,
                optimisticConversation: .existingConversation(
                    ConversationReference(objectID: conversation.objectID)
                )
            )
        )

        XCTAssertEqual(metadata.threadId, "self-thread")
        XCTAssertEqual(metadata.recipientEmails, ["me@example.com"])
    }

    func testBuildReplyMetadata_withoutTargetPreservesSelfEvidenceAtThreadlessLocalBarrier() async throws {
        let context: NSManagedObjectContext = viewContext
        let conversation = makeReplyConversation(in: context, friendEmail: "ME@example.com")
        try context.obtainPermanentIDs(for: [conversation])
        let sendService = GmailSendService(
            viewContext: context,
            authSession: makeTestAuthSession(userEmail: "me@example.com")
        )
        let handle = try await sendService.createOptimisticMessage(
            to: ["me@example.com"],
            body: "First note",
            optimisticConversation: .existingConversation(
                ConversationReference(objectID: conversation.objectID)
            )
        )
        let note = try XCTUnwrap(
            try context.existingObject(with: handle.optimisticMessageObjectID) as? Message
        )
        XCTAssertEqual(note.gmThreadId, "")
        XCTAssertNotNil(OutboundSendDeliveryState.localOptimisticMessageID(for: note))

        let metadata = try await makeBuilder().buildReplyMetadata(
            .init(
                conversationObjectID: conversation.objectID,
                replyingToMessageObjectID: nil,
                optimisticConversation: .existingConversation(
                    ConversationReference(objectID: conversation.objectID)
                )
            )
        )

        XCTAssertNil(metadata.threadId)
        XCTAssertEqual(metadata.recipientEmails, ["me@example.com"])
    }

    func testBuildReplyMetadata_rowlessSelfMessageDoesNotManufactureRecipientForTargetOrAnchor() async throws {
        let context: NSManagedObjectContext = viewContext
        let conversation = makeReplyConversation(in: context, friendEmail: "ME@example.com")
        let note = MessageBuilder()
            .withId("legacy-rowless-self-note")
            .withThreadId("self-thread")
            .withSender(email: "me@example.com", name: "Me")
            .fromMe()
            .inConversation(conversation)
            .build(in: context)
        try context.obtainPermanentIDs(for: [conversation, note])
        XCTAssertEqual(note.participants?.count ?? 0, 0)

        for replyingToMessageObjectID in [note.objectID, nil] {
            let metadata = try await makeBuilder().buildReplyMetadata(
                .init(
                    conversationObjectID: conversation.objectID,
                    replyingToMessageObjectID: replyingToMessageObjectID,
                    optimisticConversation: .existingConversation(
                        ConversationReference(objectID: conversation.objectID)
                    )
                )
            )

            XCTAssertEqual(metadata.threadId, "self-thread")
            XCTAssertEqual(metadata.recipientEmails, [])
        }
    }

    func testBuildReplyMetadata_excludesHideMyEmailConversationParticipant() async throws {
        let context: NSManagedObjectContext = viewContext
        let conversation = makeReplyConversation(in: context, friendEmail: "friend@example.com")
        addConversationParticipant(
            email: "relay@icloud.com",
            displayName: "Hide My Email",
            to: conversation
        )
        let target = MessageBuilder()
            .withId("message-hme")
            .withThreadId("thread-hme")
            .withSender(email: "friend@example.com", name: "Friend")
            .inConversation(conversation)
            .build(in: context)
        try context.obtainPermanentIDs(for: [conversation, target])

        let metadata = try await makeBuilder().buildReplyMetadata(
            .init(
                conversationObjectID: conversation.objectID,
                replyingToMessageObjectID: target.objectID,
                optimisticConversation: .existingConversation(
                    ConversationReference(objectID: conversation.objectID)
                )
            )
        )

        XCTAssertEqual(metadata.recipientEmails, ["friend@example.com"])
    }

    func testBuildReplyMetadata_defersOriginalHTMLResolution() async throws {
        let context: NSManagedObjectContext = viewContext
        let conversation = makeReplyConversation(in: context, friendEmail: "friend@example.com")
        let replyingTo = MessageBuilder()
            .withId("deferred-html-message")
            .withThreadId("deferred-html-thread")
            .withSender(email: "friend@example.com", name: "Friend")
            .withBody("Original body")
            .inConversation(conversation)
            .build(in: context)
        try context.obtainPermanentIDs(for: [conversation, replyingTo])
        let probe = ReplyQuotedHTMLProbe(result: "<html><body>Deferred HTML</body></html>")
        let resolver = ReplyQuotedHTMLResolver { source in
            probe.load(source)
        }

        let metadata = try await makeBuilder(
            replyQuotedHTMLResolver: resolver
        ).buildReplyMetadata(
            .init(
                conversationObjectID: conversation.objectID,
                replyingToMessageObjectID: replyingTo.objectID,
                optimisticConversation: .existingConversation(
                    ConversationReference(objectID: conversation.objectID)
                )
            )
        )

        XCTAssertNil(metadata.originalMessage?.originalHTML)
        XCTAssertEqual(probe.snapshot.callCount, 0)

        let resolvedOriginal = await metadata.originalMessage?.resolvingOriginalHTML()

        XCTAssertEqual(probe.snapshot.callCount, 1)
        XCTAssertEqual(probe.snapshot.messageIDs, ["deferred-html-message"])
        XCTAssertEqual(resolvedOriginal?.originalHTML, "<html><body>Deferred HTML</body></html>")
    }

    func testBuildReplyMetadata_targetedReplyDoesNotMaterializeConversationMessages() async throws {
        let context: NSManagedObjectContext = viewContext
        let conversation = makeReplyConversation(in: context, friendEmail: "friend@example.com")
        let replyingTo = MessageBuilder()
            .withId("target-message")
            .withThreadId("target-thread")
            .withDate(Date(timeIntervalSince1970: 1_000))
            .withSender(email: "friend@example.com", name: "Friend")
            .inConversation(conversation)
            .build(in: context)

        for index in 0..<100 {
            _ = MessageBuilder()
                .withId("history-\(index)")
                .withThreadId("target-thread")
                .withDate(Date(timeIntervalSince1970: TimeInterval(index)))
                .withSender(email: "friend@example.com", name: "Friend")
                .inConversation(conversation)
                .build(in: context)
        }

        try saveViewContext()
        let conversationID = conversation.objectID
        let replyingToID = replyingTo.objectID
        viewContext.reset()
        let faultedConversation = try XCTUnwrap(
            try context.existingObject(with: conversationID) as? Conversation
        )
        XCTAssertTrue(faultedConversation.hasFault(forRelationshipNamed: "messages"))

        _ = try await makeBuilder().buildReplyMetadata(
            .init(
                conversationObjectID: conversationID,
                replyingToMessageObjectID: replyingToID,
                optimisticConversation: .existingConversation(
                    ConversationReference(objectID: conversationID)
                )
            )
        )

        XCTAssertTrue(
            faultedConversation.hasFault(forRelationshipNamed: "messages"),
            "A targeted reply should use bounded message fetches instead of realizing the whole relationship"
        )
    }

    func testBuildReplyMetadata_targetedReplyUsesOlderHintAcrossPendingPageBoundary() async throws {
        let context: NSManagedObjectContext = viewContext
        let conversation = makeReplyConversation(in: context, friendEmail: "friend@example.com")
        let account = AccountBuilder()
            .withEmail("me@example.com")
            .build(in: context)
        account.sendAsAliasesArray = sendAsAliases

        let olderInbound = MessageBuilder()
            .withId("older-inbound-with-alias")
            .withThreadId("target-thread")
            .withDate(Date(timeIntervalSince1970: 100))
            .withSender(email: "friend@example.com", name: "Friend")
            .inConversation(conversation)
            .build(in: context)
        olderInbound.deliveredToAddress = "alias@example.com"
        olderInbound.replyFromAddress = "alias@example.com"

        for index in 0..<31 {
            _ = MessageBuilder()
                .withId("newer-inbound-without-alias-\(index)")
                .withThreadId("target-thread")
                .withDate(Date(timeIntervalSince1970: TimeInterval(200 + index)))
                .withSender(email: "friend@example.com", name: "Friend")
                .inConversation(conversation)
                .build(in: context)
        }
        try saveViewContext()

        let replyingTo = MessageBuilder()
            .withId("newer-target-without-alias")
            .withThreadId("target-thread")
            .withDate(Date(timeIntervalSince1970: 1_000))
            .withSender(email: "friend@example.com", name: "Friend")
            .inConversation(conversation)
            .build(in: context)
        try context.obtainPermanentIDs(for: [replyingTo])

        let metadata = try await makeBuilder(userEmail: "me@example.com").buildReplyMetadata(
            .init(
                conversationObjectID: conversation.objectID,
                replyingToMessageObjectID: replyingTo.objectID,
                optimisticConversation: .existingConversation(
                    ConversationReference(objectID: conversation.objectID)
                )
            )
        )

        XCTAssertEqual(metadata.fromEmail, "alias@example.com")
    }

    func testBuildReplyMetadata_targetWithoutThreadIdDoesNotUseConversationThread() async throws {
        let context: NSManagedObjectContext = viewContext
        let conversation = makeReplyConversation(in: context, friendEmail: "friend@example.com")
        let replyingTo = MessageBuilder()
            .withId("message-without-thread")
            .withDate(Date(timeIntervalSince1970: 100))
            .withSender(email: "friend@example.com", name: "Friend")
            .inConversation(conversation)
            .build(in: context)
        replyingTo.gmThreadId = ""
        let otherMessage = MessageBuilder()
            .withId("other-message-with-thread")
            .withThreadId("other-thread")
            .withDate(Date(timeIntervalSince1970: 200))
            .withSender(email: "friend@example.com", name: "Friend")
            .inConversation(conversation)
            .build(in: context)
        try context.obtainPermanentIDs(for: [conversation, replyingTo, otherMessage])

        do {
            _ = try await makeBuilder().buildReplyMetadata(
                .init(
                    conversationObjectID: conversation.objectID,
                    replyingToMessageObjectID: replyingTo.objectID,
                    optimisticConversation: .existingConversation(
                        ConversationReference(objectID: conversation.objectID)
                    )
                )
            )
            XCTFail("Expected replyTargetUnavailable")
        } catch {
            guard case GmailSendService.SendError.replyTargetUnavailable = error else {
                return XCTFail("Expected replyTargetUnavailable, got \(error)")
            }
        }
    }

    func testBuildReplyMetadata_usesCurrentManagedObjectValuesAfterRequestCreation() async throws {
        let context: NSManagedObjectContext = viewContext
        let conversation = makeReplyConversation(in: context, friendEmail: "before@example.com")
        let replyingTo = MessageBuilder()
            .withId("message-1")
            .withThreadId("thread-before")
            .withSubject("Before Subject")
            .withSender(email: "before@example.com", name: "Before Friend")
            .withBody("Before body")
            .inConversation(conversation)
            .build(in: context)
        try context.obtainPermanentIDs(for: [conversation, replyingTo])
        replyingTo.messageId = "<before@example.com>"
        replyingTo.references = "<ref-before@example.com>"
        _ = htmlContentHandler.saveHTML(
            "<html><body><p>Before HTML</p></body></html>",
            for: replyingTo.id
        )

        let replyContext = makeBuilder().build(
            conversationObjectID: conversation.objectID,
            replyingToMessageObjectID: replyingTo.objectID,
            optimisticConversation: .existingConversation(
                ConversationReference(objectID: conversation.objectID)
            )
        )

        let updatedFriend = try XCTUnwrap(
            Array(conversation.participants ?? [])
                .compactMap(\.person)
                .first { $0.email == "before@example.com" }
        )
        updatedFriend.email = "after@example.com"
        updatedFriend.displayName = "After Friend"
        replyingTo.gmThreadId = "thread-after"
        replyingTo.subject = "After Subject"
        replyingTo.messageId = "<after@example.com>"
        replyingTo.references = "<ref-after@example.com>"
        replyingTo.bodyText = "After body"
        replyingTo.senderName = "After Friend"
        replyingTo.senderEmail = "after@example.com"
        _ = htmlContentHandler.saveHTML(
            "<html><body><p>After HTML</p></body></html>",
            for: replyingTo.id
        )

        let metadata = try await makeBuilder().buildReplyMetadata(replyContext)

        XCTAssertEqual(metadata.recipientEmails, ["after@example.com"])
        XCTAssertEqual(metadata.subject, "Re: After Subject")
        XCTAssertEqual(metadata.threadId, "thread-after")
        XCTAssertEqual(metadata.inReplyTo, "<after@example.com>")
        XCTAssertEqual(metadata.references, ["<ref-after@example.com>", "<after@example.com>"])
        XCTAssertEqual(metadata.originalMessage?.senderName, "After Friend")
        XCTAssertEqual(metadata.originalMessage?.senderEmail, "after@example.com")
        XCTAssertEqual(metadata.originalMessage?.body, "After body")
        XCTAssertNil(metadata.originalMessage?.originalHTML)
        let resolvedOriginal = await metadata.originalMessage?.resolvingOriginalHTML()
        XCTAssertTrue(resolvedOriginal?.originalHTML?.contains("After HTML") == true)
        XCTAssertFalse(resolvedOriginal?.originalHTML?.contains("Before HTML") == true)
    }

    func testBuildReplyMetadata_withoutReplyTargetUsesLatestInboundReplyFromAlias() async throws {
        let context: NSManagedObjectContext = viewContext
        let conversation = makeReplyConversation(in: context, friendEmail: "friend@example.com")
        let account = AccountBuilder()
            .withEmail("me@example.com")
            .build(in: context)
        account.sendAsAliasesArray = sendAsAliases

        let inbound = MessageBuilder()
            .withId("inbound-alias")
            .withThreadId("thread-alias")
            .withSender(email: "friend@example.com", name: "Friend")
            .withDate(Date(timeIntervalSince1970: 100))
            .inConversation(conversation)
            .build(in: context)
        inbound.deliveredToAddress = "alias@example.com"
        inbound.replyFromAddress = "alias@example.com"

        _ = MessageBuilder()
            .withId("newer-inbound-without-hint")
            .withThreadId("thread-alias")
            .withSender(email: "friend@example.com", name: "Friend")
            .withDate(Date(timeIntervalSince1970: 150))
            .inConversation(conversation)
            .build(in: context)

        _ = MessageBuilder()
            .withId("latest-optimistic")
            .withThreadId("thread-alias")
            .withSender(email: "me@example.com", name: "Me")
            .withDate(Date(timeIntervalSince1970: 200))
            .fromMe()
            .inConversation(conversation)
            .build(in: context)
        var optimisticObjects = Array(conversation.messages ?? []).map { $0 as NSManagedObject }
        optimisticObjects.append(conversation)
        try context.obtainPermanentIDs(for: optimisticObjects)

        let metadata = try await makeBuilder(userEmail: "me@example.com").buildReplyMetadata(
            .init(
                conversationObjectID: conversation.objectID,
                replyingToMessageObjectID: nil,
                optimisticConversation: .existingConversation(
                    ConversationReference(objectID: conversation.objectID)
                )
            )
        )

        XCTAssertEqual(metadata.fromEmail, "alias@example.com")
        XCTAssertEqual(metadata.threadId, "thread-alias")
        XCTAssertEqual(metadata.recipientEmails, ["friend@example.com"])
    }

    func testBuildReplyMetadata_withoutTargetSkipsLocalSendsAndEmptyThreads() async throws {
        // Revert-check: ReplyConversationSnapshot's nonListMessages.first
        // fallback selects a local or thread-less row instead of the server row.
        let context: NSManagedObjectContext = viewContext
        let conversation = makeReplyConversation(in: context, friendEmail: "friend@example.com")
        _ = MessageBuilder()
            .withThreadId("server-thread")
            .withDate(Date(timeIntervalSince1970: 100))
            .inConversation(conversation)
            .build(in: context)
        let localID = UUID().uuidString
        let localMessage = MessageBuilder()
            .withId(localID)
            .withThreadId("unconfirmed-thread")
            .withDate(Date(timeIntervalSince1970: 200))
            .fromMe()
            .inConversation(conversation)
            .build(in: context)
        localMessage.messageId = MimeBuilder.messageId(forOptimisticMessageID: localID)
        try context.obtainPermanentIDs(for: [conversation, localMessage])
        let record = context.insertTestObject(OutboundSendMutationRecord.self)
        record.id = localID
        record.createdAt = Date()
        record.conversationId = conversation.id
        record.conversationURI = conversation.objectID.uriRepresentation().absoluteString
        record.hidden = false
        record.newlyInsertedConversation = false

        let builder = makeBuilder()
        let replyContext = builder.build(
            conversationObjectID: conversation.objectID,
            replyingToMessageObjectID: nil,
            optimisticConversation: nil
        )
        let localMarkers: [String?] = [
            nil,
            OutboundSendRemoteState.inFlightMessageID,
            OutboundSendRemoteState.notSentMessageID,
            OutboundSendRemoteState.ambiguousMessageID
        ]
        for marker in localMarkers {
            record.remoteCommittedMessageId = marker
            record.remoteCommittedThreadId = nil
            let metadata = try await builder.buildReplyMetadata(replyContext)
            XCTAssertEqual(metadata.threadId, "server-thread")
        }

        // A legacy row can lack a thread even without an outbound marker.
        context.delete(record)
        localMessage.messageId = nil
        for emptyThread in ["", " \n "] {
            localMessage.gmThreadId = emptyThread
            let metadata = try await builder.buildReplyMetadata(replyContext)
            XCTAssertEqual(metadata.threadId, "server-thread")
        }
    }

    func testBuildReplyMetadata_withoutTargetThreadlessLocalSendBlocksOlderThread() async throws {
        let context: NSManagedObjectContext = viewContext
        let conversation = makeReplyConversation(in: context, friendEmail: "friend@example.com")
        _ = MessageBuilder()
            .withThreadId("unrelated-older-thread")
            .withDate(Date(timeIntervalSince1970: 100))
            .inConversation(conversation)
            .build(in: context)
        let localSend = try makeLocalSend(
            in: conversation,
            threadId: "",
            date: Date(timeIntervalSince1970: 200)
        )
        let builder = makeBuilder()
        let replyContext = builder.build(
            conversationObjectID: conversation.objectID,
            replyingToMessageObjectID: nil,
            optimisticConversation: nil
        )
        let localMarkers: [String?] = [
            nil,
            OutboundSendRemoteState.inFlightMessageID,
            OutboundSendRemoteState.ambiguousMessageID,
            OutboundSendRemoteState.notSentMessageID
        ]

        for marker in localMarkers {
            for emptyThread in ["", " \n\t "] {
                localSend.record.remoteCommittedMessageId = marker
                localSend.message.gmThreadId = emptyThread
                try context.save()

                let metadata = try await builder.buildReplyMetadata(replyContext)

                XCTAssertNil(
                    metadata.threadId,
                    "A fresh local send must block the older thread for \(marker ?? "pending") with \(String(reflecting: emptyThread))"
                )
                XCTAssertEqual(metadata.recipientEmails, ["friend@example.com"])
            }
        }

        context.delete(localSend.record)
        for emptyThread in ["", " \n\t "] {
            localSend.message.gmThreadId = emptyThread
            try context.save()

            let metadata = try await builder.buildReplyMetadata(replyContext)
            XCTAssertNil(
                metadata.threadId,
                "An identifiable optimistic send must remain a barrier even without its durable record"
            )
        }
    }

    func testBuildReplyMetadata_withoutTargetPreservesLocalBarrierUntilReconciliation() async throws {
        let context: NSManagedObjectContext = viewContext
        let conversation = makeReplyConversation(in: context, friendEmail: "friend@example.com")
        _ = MessageBuilder()
            .withThreadId("unrelated-older-thread")
            .withDate(Date(timeIntervalSince1970: 100))
            .inConversation(conversation)
            .build(in: context)
        let freshSend = try makeLocalSend(
            in: conversation,
            threadId: "",
            date: Date(timeIntervalSince1970: 200)
        )
        freshSend.record.remoteCommittedMessageId = OutboundSendRemoteState.ambiguousMessageID
        _ = try makeLocalSend(
            in: conversation,
            threadId: "unconfirmed-newer-thread",
            date: Date(timeIntervalSince1970: 300)
        )
        try context.save()
        let builder = makeBuilder()
        let replyContext = builder.build(
            conversationObjectID: conversation.objectID,
            replyingToMessageObjectID: nil,
            optimisticConversation: nil
        )

        let unresolvedMetadata = try await builder.buildReplyMetadata(replyContext)
        XCTAssertNil(
            unresolvedMetadata.threadId,
            "Skipping a newer thread-bearing local send must still encounter the fresh-send barrier"
        )

        freshSend.record.remoteCommittedMessageId = "committed-message"
        freshSend.record.remoteCommittedThreadId = "new-durable-thread"
        try context.save()

        let awaitingReconciliationMetadata = try await builder.buildReplyMetadata(replyContext)
        XCTAssertNil(
            awaitingReconciliationMetadata.threadId,
            "Remote commit must not expose the older thread before reconciliation updates the message"
        )

        freshSend.message.gmThreadId = "new-durable-thread"
        try context.save()

        let committedMetadata = try await builder.buildReplyMetadata(replyContext)
        XCTAssertEqual(committedMetadata.threadId, "new-durable-thread")

        freshSend.message.id = "committed-message"
        context.delete(freshSend.record)
        try context.save()

        let reconciledMetadata = try await builder.buildReplyMetadata(replyContext)
        XCTAssertEqual(reconciledMetadata.threadId, "new-durable-thread")
    }

    func testBuildReplyMetadata_backfillsReplyFromAliasFromLegacyTargetParticipants() async throws {
        let context: NSManagedObjectContext = viewContext
        let conversation = makeReplyConversation(in: context, friendEmail: "friend@example.com")
        let account = AccountBuilder()
            .withEmail("me@example.com")
            .build(in: context)
        account.sendAsAliasesArray = sendAsAliases

        let replyingTo = MessageBuilder()
            .withId("legacy-target")
            .withThreadId("thread-legacy")
            .withSender(email: "friend@example.com", name: "Friend")
            .inConversation(conversation)
            .build(in: context)
        let aliasPerson = PersonBuilder()
            .withEmail("alias@example.com")
            .noDisplayName()
            .build(in: context)
        addMessageParticipant(person: aliasPerson, kind: .to, to: replyingTo)
        try context.obtainPermanentIDs(for: [conversation, replyingTo])

        let metadata = try await makeBuilder(userEmail: "me@example.com").buildReplyMetadata(
            .init(
                conversationObjectID: conversation.objectID,
                replyingToMessageObjectID: replyingTo.objectID,
                optimisticConversation: .existingConversation(
                    ConversationReference(objectID: conversation.objectID)
                )
            )
        )

        XCTAssertEqual(metadata.fromEmail, "alias@example.com")
    }

    func testBuildReplyMetadata_usesLegacyAccountAliasesWhenSendAsAliasesAreMissing() async throws {
        let context: NSManagedObjectContext = viewContext
        let conversation = makeReplyConversation(in: context, friendEmail: "friend@example.com")
        _ = AccountBuilder()
            .withEmail("me@example.com")
            .withAliases(["alias@example.com"])
            .build(in: context)

        let replyingTo = MessageBuilder()
            .withId("legacy-alias-account")
            .withThreadId("thread-legacy-account")
            .withSender(email: "friend@example.com", name: "Friend")
            .inConversation(conversation)
            .build(in: context)
        replyingTo.deliveredToAddress = "alias@example.com"
        replyingTo.replyFromAddress = "alias@example.com"
        try context.obtainPermanentIDs(for: [conversation, replyingTo])

        let metadata = try await makeBuilder(userEmail: "me@example.com").buildReplyMetadata(
            .init(
                conversationObjectID: conversation.objectID,
                replyingToMessageObjectID: replyingTo.objectID,
                optimisticConversation: .existingConversation(
                    ConversationReference(objectID: conversation.objectID)
                )
            )
        )

        XCTAssertEqual(metadata.fromEmail, "alias@example.com")
    }

    func testBuildReplyMetadata_listReplyUsesSelectedLaterMessageParticipants() async throws {
        let fixture = try makeRotatingListConversation()
        let newestMatchingMessage = MessageBuilder()
            .withId("newest-matching-list-message")
            .withThreadId("thread-newest-matching")
            .withDate(Date(timeIntervalSince1970: 300))
            .withSender(email: "newest-sender@example.com", name: "Newest Sender")
            .withListId("list.example.com")
            .inConversation(fixture.conversation)
            .build(in: viewContext)
        addMessageParticipant(email: "newest-sender@example.com", kind: .from, to: newestMatchingMessage)
        addMessageParticipant(email: "me@example.com", kind: .to, to: newestMatchingMessage)
        addMessageParticipant(email: "newest-list@example.com", kind: .to, to: newestMatchingMessage)
        try viewContext.obtainPermanentIDs(for: [newestMatchingMessage])

        let metadata = try await makeBuilder(userEmail: "me@example.com").buildReplyMetadata(
            .init(
                conversationObjectID: fixture.conversation.objectID,
                replyingToMessageObjectID: fixture.laterMessage.objectID,
                optimisticConversation: .existingConversation(
                    ConversationReference(objectID: fixture.conversation.objectID)
                )
            )
        )

        XCTAssertEqual(
            metadata.recipientEmails,
            [
                "later-sender@example.com",
                "later-list@example.com",
                "later-cc@example.com"
            ]
        )
        XCTAssertEqual(metadata.threadId, "thread-later")
        XCTAssertFalse(metadata.recipientEmails.contains("first-sender@example.com"))
        XCTAssertFalse(metadata.recipientEmails.contains("first-list@example.com"))
        XCTAssertFalse(metadata.recipientEmails.contains("first-cc@example.com"))
        XCTAssertFalse(metadata.recipientEmails.contains("newest-sender@example.com"))
        XCTAssertFalse(metadata.recipientEmails.contains("newest-list@example.com"))
        XCTAssertFalse(metadata.recipientEmails.contains("later-bcc@example.com"))
    }

    func testBuildReplyMetadata_listTargetUsesGitHubReplyToMailboxListInsteadOfFrom() async throws {
        let fixture = try makeRotatingListConversation()
        fixture.laterMessage.replyTo =
            #""octocat/Hello-World" <reply+123456@reply.github.com>, Later List <LATER-LIST@example.com>"#

        let metadata = try await makeBuilder(userEmail: "me@example.com").buildReplyMetadata(
            .init(
                conversationObjectID: fixture.conversation.objectID,
                replyingToMessageObjectID: fixture.laterMessage.objectID,
                optimisticConversation: .existingConversation(
                    ConversationReference(objectID: fixture.conversation.objectID)
                )
            )
        )

        XCTAssertEqual(
            metadata.recipientEmails,
            [
                "reply+123456@reply.github.com",
                "later-list@example.com",
                "later-cc@example.com"
            ]
        )
        XCTAssertFalse(metadata.recipientEmails.contains("later-sender@example.com"))
        XCTAssertFalse(metadata.recipientEmails.contains("later-bcc@example.com"))
        XCTAssertEqual(
            metadata.recipientEmails.filter {
                EmailNormalizer.normalize($0) == "later-list@example.com"
            }.count,
            1
        )
    }

    func testBuildReplyMetadata_listTargetExcludesHideMyEmailParticipant() async throws {
        let fixture = try makeRotatingListConversation()
        fixture.laterMessage.replyTo =
            #"Hide My Email <reply-relay@icloud.com>, Reply Control <reply-control@example.com>"#
        let relay = PersonBuilder()
            .withEmail("participant-relay@icloud.com")
            .withDisplayName("Hide My Email")
            .build(in: viewContext)
        addMessageParticipant(person: relay, kind: .cc, to: fixture.laterMessage)

        let metadata = try await makeBuilder(userEmail: "me@example.com").buildReplyMetadata(
            .init(
                conversationObjectID: fixture.conversation.objectID,
                replyingToMessageObjectID: fixture.laterMessage.objectID,
                optimisticConversation: .existingConversation(
                    ConversationReference(objectID: fixture.conversation.objectID)
                )
            )
        )

        XCTAssertEqual(
            metadata.recipientEmails,
            [
                "reply-control@example.com",
                "later-list@example.com",
                "later-cc@example.com"
            ]
        )
        XCTAssertFalse(metadata.recipientEmails.contains("later-sender@example.com"))
    }

    func testBuildReplyMetadata_listConversationUsesLatestInboundReplyToInsteadOfFrom() async throws {
        let fixture = try makeRotatingListConversation()
        fixture.laterMessage.replyTo = #"GitHub <reply+conversation@reply.github.com>"#

        let metadata = try await makeBuilder(userEmail: "me@example.com").buildReplyMetadata(
            .init(
                conversationObjectID: fixture.conversation.objectID,
                replyingToMessageObjectID: nil,
                optimisticConversation: .existingConversation(
                    ConversationReference(objectID: fixture.conversation.objectID)
                )
            )
        )

        XCTAssertEqual(
            metadata.recipientEmails,
            [
                "reply+conversation@reply.github.com",
                "later-list@example.com",
                "later-cc@example.com"
            ]
        )
        XCTAssertFalse(metadata.recipientEmails.contains("later-sender@example.com"))
        XCTAssertFalse(metadata.recipientEmails.contains("later-bcc@example.com"))
    }

    func testBuildReplyMetadata_listTargetWithInvalidReplyToFallsBackToFrom() async throws {
        let fixture = try makeRotatingListConversation()
        fixture.laterMessage.replyTo = "undisclosed-recipients:;"

        let metadata = try await makeBuilder(userEmail: "me@example.com").buildReplyMetadata(
            .init(
                conversationObjectID: fixture.conversation.objectID,
                replyingToMessageObjectID: fixture.laterMessage.objectID,
                optimisticConversation: .existingConversation(
                    ConversationReference(objectID: fixture.conversation.objectID)
                )
            )
        )

        XCTAssertEqual(
            metadata.recipientEmails,
            [
                "later-sender@example.com",
                "later-list@example.com",
                "later-cc@example.com"
            ]
        )
        XCTAssertFalse(metadata.recipientEmails.contains("later-bcc@example.com"))
    }

    func testBuildReplyMetadata_listTargetWithoutParticipantsDoesNotBorrowAnotherThreadsRecipients() async throws {
        let fixture = try makeRotatingListConversation()
        let reconciledOptimisticMessage = MessageBuilder()
            .withId("reconciled-optimistic")
            .withThreadId("thread-optimistic")
            .withSubject("Optimistic Subject")
            .withDate(Date(timeIntervalSince1970: 300))
            .withSender(email: "me@example.com", name: "Me")
            .withListId("list.example.com")
            .fromMe()
            .inConversation(fixture.conversation)
            .build(in: viewContext)
        reconciledOptimisticMessage.messageId = "<optimistic@example.com>"
        try viewContext.obtainPermanentIDs(for: [reconciledOptimisticMessage])

        let metadata = try await makeBuilder(userEmail: "me@example.com").buildReplyMetadata(
            .init(
                conversationObjectID: fixture.conversation.objectID,
                replyingToMessageObjectID: reconciledOptimisticMessage.objectID,
                optimisticConversation: .existingConversation(
                    ConversationReference(objectID: fixture.conversation.objectID)
                )
            )
        )

        XCTAssertEqual(metadata.recipientEmails, [])
        XCTAssertEqual(metadata.subject, "Re: Optimistic Subject")
        XCTAssertEqual(metadata.threadId, "thread-optimistic")
        XCTAssertEqual(metadata.inReplyTo, "<optimistic@example.com>")
    }

    func testBuildReplyMetadata_listReplyWithoutTargetUsesLatestInboundListMessageParticipants() async throws {
        let fixture = try makeRotatingListConversation()
        let newerOtherListMessage = MessageBuilder()
            .withId("newer-other-list")
            .withThreadId("thread-other-list")
            .withDate(Date(timeIntervalSince1970: 250))
            .withSender(email: "other-sender@example.com", name: "Other Sender")
            .withListId("other.example.com")
            .inConversation(fixture.conversation)
            .build(in: viewContext)
        addMessageParticipant(email: "other-sender@example.com", kind: .from, to: newerOtherListMessage)
        addMessageParticipant(email: "other-list@example.com", kind: .to, to: newerOtherListMessage)
        let latestOutbound = MessageBuilder()
            .withId("latest-outbound")
            .withThreadId("thread-list")
            .withDate(Date(timeIntervalSince1970: 300))
            .withSender(email: "me@example.com", name: "Me")
            .withListId("list.example.com")
            .fromMe()
            .inConversation(fixture.conversation)
            .build(in: viewContext)
        addMessageParticipant(email: "me@example.com", kind: .from, to: latestOutbound)
        addMessageParticipant(email: "outbound-only@example.com", kind: .to, to: latestOutbound)
        try viewContext.obtainPermanentIDs(
            for: [newerOtherListMessage, latestOutbound]
        )

        let metadata = try await makeBuilder(userEmail: "me@example.com").buildReplyMetadata(
            .init(
                conversationObjectID: fixture.conversation.objectID,
                replyingToMessageObjectID: nil,
                optimisticConversation: .existingConversation(
                    ConversationReference(objectID: fixture.conversation.objectID)
                )
            )
        )

        XCTAssertEqual(
            metadata.recipientEmails,
            [
                "later-sender@example.com",
                "later-list@example.com",
                "later-cc@example.com"
            ]
        )
        XCTAssertEqual(metadata.threadId, "thread-later")
        XCTAssertFalse(metadata.recipientEmails.contains("first-sender@example.com"))
        XCTAssertFalse(metadata.recipientEmails.contains("other-sender@example.com"))
        XCTAssertFalse(metadata.recipientEmails.contains("other-list@example.com"))
        XCTAssertFalse(metadata.recipientEmails.contains("outbound-only@example.com"))
        XCTAssertFalse(metadata.recipientEmails.contains("later-bcc@example.com"))
    }

    func testBuildReplyMetadata_listReplyWithoutMatchingInboundNeverUsesConversationParticipants() async throws {
        let context: NSManagedObjectContext = viewContext
        let conversation = ConversationBuilder()
            .asList()
            .withListId("expected.example.com")
            .withDisplayName("Expected List")
            .visible()
            .build(in: context)
        addConversationParticipant(email: "stale-first-sender@example.com", to: conversation)
        addConversationParticipant(email: "stale-first-list@example.com", to: conversation)

        let otherListMessage = MessageBuilder()
            .withId("only-other-list-message")
            .withThreadId("thread-other")
            .withDate(Date(timeIntervalSince1970: 100))
            .withListId("other.example.com")
            .inConversation(conversation)
            .build(in: context)
        addMessageParticipant(email: "other-sender@example.com", kind: .from, to: otherListMessage)
        addMessageParticipant(email: "other-list@example.com", kind: .to, to: otherListMessage)
        try context.obtainPermanentIDs(for: [conversation, otherListMessage])

        let metadata = try await makeBuilder(userEmail: "me@example.com").buildReplyMetadata(
            .init(
                conversationObjectID: conversation.objectID,
                replyingToMessageObjectID: nil,
                optimisticConversation: .existingConversation(
                    ConversationReference(objectID: conversation.objectID)
                )
            )
        )

        XCTAssertEqual(metadata.recipientEmails, [])
        XCTAssertNil(metadata.threadId)
    }

    func testBuildReplyMetadata_listReplyExcludesSelfContactAlias() async throws {
        let fixture = try makeRotatingListConversation()
        addMessageParticipant(
            email: "my-self-contact-alias@example.com",
            kind: .cc,
            to: fixture.laterMessage
        )

        let metadata = try await makeBuilder(
            userEmail: "me@example.com",
            userAliases: ["me@example.com", "my-self-contact-alias@example.com"]
        ).buildReplyMetadata(
            .init(
                conversationObjectID: fixture.conversation.objectID,
                replyingToMessageObjectID: fixture.laterMessage.objectID,
                optimisticConversation: .existingConversation(
                    ConversationReference(objectID: fixture.conversation.objectID)
                )
            )
        )

        XCTAssertFalse(metadata.recipientEmails.contains("my-self-contact-alias@example.com"))
        XCTAssertTrue(metadata.recipientEmails.contains("later-sender@example.com"))
    }

    func testBuildReplyMetadata_rejectsTargetThatTransitionsToTerminalLocalSendState() async throws {
        let context: NSManagedObjectContext = viewContext
        let conversation = makeReplyConversation(
            in: context,
            friendEmail: "friend@example.com"
        )
        let optimisticID = UUID().uuidString
        let selectedMessage = MessageBuilder()
            .withId(optimisticID)
            .withThreadId("optimistic-thread")
            .withSender(email: "me@example.com", name: "Me")
            .withBody("Never quote this retained local body")
            .fromMe()
            .inConversation(conversation)
            .build(in: context)
        selectedMessage.messageId = MimeBuilder.messageId(
            forOptimisticMessageID: optimisticID
        )
        addMessageParticipant(email: "me@example.com", kind: .from, to: selectedMessage)
        addMessageParticipant(email: "friend@example.com", kind: .to, to: selectedMessage)
        try context.obtainPermanentIDs(for: [conversation, selectedMessage])

        // Selection can predate the terminal transition. The send-time metadata
        // builder remains the authority even if the UI still holds this objectID.
        let replyContext = makeBuilder().build(
            conversationObjectID: conversation.objectID,
            replyingToMessageObjectID: selectedMessage.objectID,
            optimisticConversation: .existingConversation(
                ConversationReference(objectID: conversation.objectID)
            )
        )
        let record = context.insertTestObject(OutboundSendMutationRecord.self)
        record.id = optimisticID
        record.createdAt = Date()
        record.conversationId = conversation.id
        record.conversationURI = conversation.objectID.uriRepresentation().absoluteString
        record.hidden = false
        record.newlyInsertedConversation = false

        let localMarkers: [String?] = [
            nil,
            OutboundSendRemoteState.notSentMessageID,
            OutboundSendRemoteState.ambiguousMessageID
        ]
        for marker in localMarkers {
            record.remoteCommittedMessageId = marker
            record.remoteCommittedThreadId = nil
            try context.save()

            do {
                _ = try await makeBuilder().buildReplyMetadata(replyContext)
                XCTFail(
                    "Expected replyTargetUnavailable for \(marker ?? "nil local state")"
                )
            } catch {
                guard case GmailSendService.SendError.replyTargetUnavailable = error else {
                    return XCTFail("Expected replyTargetUnavailable, got \(error)")
                }
            }
        }
    }

    func testBuildReplyMetadata_listReplyFailsClosedWhenSelectedTargetReroutes() async throws {
        let fixture = try makeRotatingListConversation()
        let otherConversation = ConversationBuilder()
            .asList()
            .withListId("other.example.com")
            .withDisplayName("Other List")
            .visible()
            .build(in: viewContext)
        try viewContext.obtainPermanentIDs(for: [otherConversation])
        let replyContext = makeBuilder().build(
            conversationObjectID: fixture.conversation.objectID,
            replyingToMessageObjectID: fixture.laterMessage.objectID,
            optimisticConversation: .existingConversation(
                ConversationReference(objectID: fixture.conversation.objectID)
            )
        )

        fixture.laterMessage.conversation = otherConversation

        do {
            _ = try await makeBuilder().buildReplyMetadata(replyContext)
            XCTFail("Expected replyTargetUnavailable")
        } catch {
            guard case GmailSendService.SendError.replyTargetUnavailable = error else {
                return XCTFail("Expected replyTargetUnavailable, got \(error)")
            }
        }
    }

    func testBuildReplyMetadata_listReplyFailsClosedForMismatchedTargetListId() async throws {
        let fixture = try makeRotatingListConversation()
        let replyContext = makeBuilder().build(
            conversationObjectID: fixture.conversation.objectID,
            replyingToMessageObjectID: fixture.laterMessage.objectID,
            optimisticConversation: .existingConversation(
                ConversationReference(objectID: fixture.conversation.objectID)
            )
        )

        fixture.laterMessage.listId = "other.example.com"

        do {
            _ = try await makeBuilder().buildReplyMetadata(replyContext)
            XCTFail("Expected replyTargetUnavailable")
        } catch {
            guard case GmailSendService.SendError.replyTargetUnavailable = error else {
                return XCTFail("Expected replyTargetUnavailable, got \(error)")
            }
        }
    }

    func testBuildReplyMetadata_nilTargetFailsClosedWhenConversationDrainsDuringAliasLoad() async throws {
        let context: NSManagedObjectContext = viewContext
        let conversation = makeReplyConversation(
            in: context,
            friendEmail: "friend@example.com"
        )
        try context.obtainPermanentIDs(for: [conversation])
        let aliasLoader = SuspendedUserAliasLoader()
        let builder = makeBuilder(
            loadUserAliases: { await aliasLoader.load() }
        )
        let replyContext = builder.build(
            conversationObjectID: conversation.objectID,
            replyingToMessageObjectID: nil,
            optimisticConversation: .existingConversation(
                ConversationReference(objectID: conversation.objectID)
            )
        )

        let metadataTask = Task {
            try await builder.buildReplyMetadata(replyContext)
        }
        await aliasLoader.waitUntilStarted()

        conversation.hidden = true
        conversation.archivedAt = Date()
        conversation.lastMessageDate = nil
        aliasLoader.resume()

        do {
            _ = try await metadataTask.value
            XCTFail("Expected replyConversationUnavailable")
        } catch {
            // The chat itself moved, so the selected-message advice of
            // `replyTargetUnavailable` would send the user in circles.
            // Revert-check: throwing `replyTargetUnavailable` again from
            // `OutboundReplyContextBuilder.buildReplyMetadata`'s post-alias
            // anchor guard fails this.
            guard case GmailSendService.SendError.replyConversationUnavailable = error else {
                return XCTFail("Expected replyConversationUnavailable, got \(error)")
            }
        }
    }

    /// Saves the suite's main-queue context directly; the test body is
    /// already on its queue. `TestCoreDataStack.saveViewContext()` would save
    /// the stack's private-queue context instead (see the type comment).
    private func saveViewContext() throws {
        guard viewContext.hasChanges else { return }
        try viewContext.save()
    }

    func testBuildReplyMetadata_nonListReplyUsesReplyToAndPreservesOtherRecipients() async throws {
        let conversation = makeReplyConversation(in: viewContext, friendEmail: "noreply@example.com")
        let message = MessageBuilder()
            .withId("ordinary-reply-to")
            .withThreadId("ordinary-thread")
            .withSender(email: "noreply@example.com", name: "Service")
            .inConversation(conversation)
            .build(in: viewContext)
        message.replyTo = "Support <agent@example.com>, COPY@example.com"
        addMessageParticipant(email: "noreply@example.com", kind: .from, to: message)
        addMessageParticipant(email: "me@example.com", kind: .to, to: message)
        addMessageParticipant(email: "copy@example.com", kind: .cc, to: message)
        addMessageParticipant(email: "hidden@example.com", kind: .bcc, to: message)
        try viewContext.obtainPermanentIDs(for: [conversation, message])

        for target in [message.objectID, nil] {
            let metadata = try await makeBuilder().buildReplyMetadata(.init(
                conversationObjectID: conversation.objectID,
                replyingToMessageObjectID: target,
                optimisticConversation: nil
            ))
            XCTAssertEqual(metadata.recipientEmails, ["agent@example.com", "copy@example.com"])
        }
    }

    func testBuildReplyMetadata_outgoingFollowUpUsesRecipientsInsteadOfOwnReplyTo() async throws {
        let conversation = makeReplyConversation(in: viewContext, friendEmail: "friend@example.com")
        let message = MessageBuilder()
            .withId("outgoing-follow-up")
            .withThreadId("outgoing-thread")
            .withSender(email: "me@example.com", name: "Me")
            .fromMe()
            .inConversation(conversation)
            .build(in: viewContext)
        message.replyTo = "My reply mailbox <other-self@example.com>"
        addMessageParticipant(email: "me@example.com", kind: .from, to: message)
        addMessageParticipant(email: "friend@example.com", kind: .to, to: message)
        try viewContext.obtainPermanentIDs(for: [conversation, message])

        let metadata = try await makeBuilder().buildReplyMetadata(.init(
            conversationObjectID: conversation.objectID,
            replyingToMessageObjectID: message.objectID,
            optimisticConversation: nil
        ))
        XCTAssertEqual(metadata.recipientEmails, ["friend@example.com"])
    }

    func testBuildReplyMetadata_clearedTargetPreservesHeadersWithoutQuoteOrFullHistoryLoad() async throws {
        let conversation = makeReplyConversation(in: viewContext, friendEmail: "friend@example.com")
        for index in 0..<100 {
            _ = MessageBuilder()
                .withId("cleared-history-\(index)")
                .withThreadId("older-thread")
                .withDate(Date(timeIntervalSince1970: TimeInterval(index)))
                .inConversation(conversation)
                .build(in: viewContext)
        }
        let anchor = MessageBuilder()
            .withId("cleared-anchor")
            .withThreadId("current-thread")
            .withSubject("Current topic")
            .withDate(Date(timeIntervalSince1970: 200))
            .withSender(email: "friend@example.com", name: "Friend")
            .inConversation(conversation)
            .build(in: viewContext)
        anchor.messageId = "<current@example.com>"
        anchor.references = "<previous@example.com>"
        let pending = try makeLocalSend(
            in: conversation,
            threadId: "current-thread",
            date: Date(timeIntervalSince1970: 300)
        )
        pending.record.remoteCommittedMessageId = OutboundSendRemoteState.notSentMessageID
        try saveViewContext()
        let conversationID = conversation.objectID
        viewContext.reset()
        let coldConversation = try XCTUnwrap(
            try viewContext.existingObject(with: conversationID) as? Conversation
        )
        XCTAssertTrue(coldConversation.hasFault(forRelationshipNamed: "messages"))

        let metadata = try await makeBuilder().buildReplyMetadata(.init(
            conversationObjectID: conversationID,
            replyingToMessageObjectID: nil,
            optimisticConversation: nil
        ))

        XCTAssertEqual(metadata.threadId, "current-thread")
        XCTAssertEqual(metadata.subject, "Re: Current topic")
        XCTAssertEqual(metadata.inReplyTo, "<current@example.com>")
        XCTAssertEqual(metadata.references, ["<previous@example.com>", "<current@example.com>"])
        XCTAssertNil(metadata.originalMessage)
        XCTAssertTrue(coldConversation.hasFault(forRelationshipNamed: "messages"))
    }

    func testBuildReplyMetadata_clearedListTargetPreservesLatestPostHeadersWithoutQuote() async throws {
        let fixture = try makeRotatingListConversation()
        fixture.laterMessage.subject = "List topic"
        fixture.laterMessage.messageId = "<list-post@example.com>"
        fixture.laterMessage.references = "<list-parent@example.com>"

        let metadata = try await makeBuilder().buildReplyMetadata(.init(
            conversationObjectID: fixture.conversation.objectID,
            replyingToMessageObjectID: nil,
            optimisticConversation: nil
        ))

        XCTAssertEqual(metadata.threadId, "thread-later")
        XCTAssertEqual(metadata.subject, "Re: List topic")
        XCTAssertEqual(metadata.inReplyTo, "<list-post@example.com>")
        XCTAssertEqual(metadata.references, ["<list-parent@example.com>", "<list-post@example.com>"])
        XCTAssertNil(metadata.originalMessage)
    }

    private func makeBuilder(
        userEmail: String = "me@example.com",
        userAliases: Set<String> = [],
        replyQuotedHTMLResolver: ReplyQuotedHTMLResolver? = nil,
        loadUserAliases: (@MainActor () async -> Set<String>)? = nil
    ) -> OutboundReplyContextBuilder {
        OutboundReplyContextBuilder(
            viewContext: viewContext,
            replyMetadataBuilder: ReplyMetadataBuilder(
                authSession: makeTestAuthSession(userEmail: userEmail)
            ),
            replyHTMLContentLoader: HTMLContentLoader(
                contentHandler: htmlContentHandler,
                sanitizer: .shared
            ),
            replyQuotedHTMLResolver: replyQuotedHTMLResolver,
            loadUserAliases: loadUserAliases ?? { userAliases }
        )
    }

    private func makeReplyConversation(
        in context: NSManagedObjectContext,
        friendEmail: String
    ) -> Conversation {
        let conversation = ConversationBuilder()
            .withDisplayName("Reply Thread")
            .visible()
            .recentlyActive()
            .build(in: context)

        let me = PersonBuilder()
            .withEmail("me@example.com")
            .noDisplayName()
            .build(in: context)

        let friend = PersonBuilder()
            .withEmail(friendEmail)
            .withDisplayName("Friend")
            .build(in: context)

        let meParticipant = context.insertTestObject(ConversationParticipant.self)
        meParticipant.id = UUID()
        meParticipant.person = me
        meParticipant.participantRole = .normal
        meParticipant.conversation = conversation

        let friendParticipant = context.insertTestObject(ConversationParticipant.self)
        friendParticipant.id = UUID()
        friendParticipant.person = friend
        friendParticipant.participantRole = .normal
        friendParticipant.conversation = conversation

        return conversation
    }

    private func makeLocalSend(
        in conversation: Conversation,
        threadId: String,
        date: Date
    ) throws -> (message: Message, record: OutboundSendMutationRecord) {
        let context: NSManagedObjectContext = viewContext
        let localID = UUID().uuidString
        let message = MessageBuilder()
            .withId(localID)
            .withThreadId(threadId)
            .withDate(date)
            .withSender(email: "me@example.com", name: "Me")
            .fromMe()
            .inConversation(conversation)
            .build(in: context)
        message.messageId = MimeBuilder.messageId(forOptimisticMessageID: localID)
        try context.obtainPermanentIDs(for: [conversation, message])

        let record = context.insertTestObject(OutboundSendMutationRecord.self)
        record.id = localID
        record.createdAt = date
        record.conversationId = conversation.id
        record.conversationURI = conversation.objectID.uriRepresentation().absoluteString
        record.hidden = false
        record.newlyInsertedConversation = false
        return (message, record)
    }

    private func makeRotatingListConversation() throws -> (
        conversation: Conversation,
        laterMessage: Message
    ) {
        let context: NSManagedObjectContext = viewContext
        let conversation = ConversationBuilder()
            .asList()
            .withListId("list.example.com")
            .withDisplayName("Example List")
            .visible()
            .recentlyActive()
            .build(in: context)

        for email in [
            "me@example.com",
            "first-sender@example.com",
            "first-list@example.com",
            "first-cc@example.com"
        ] {
            let person = PersonBuilder()
                .withEmail(email)
                .noDisplayName()
                .build(in: context)
            let participant = context.insertTestObject(ConversationParticipant.self)
            participant.id = UUID()
            participant.person = person
            participant.participantRole = .normal
            participant.conversation = conversation
        }

        let firstMessage = MessageBuilder()
            .withId("first-list-message")
            .withThreadId("thread-first")
            .withDate(Date(timeIntervalSince1970: 100))
            .withSender(email: "first-sender@example.com", name: "First Sender")
            .withListId("list.example.com")
            .inConversation(conversation)
            .build(in: context)
        addMessageParticipant(email: "first-sender@example.com", kind: .from, to: firstMessage)
        addMessageParticipant(email: "me@example.com", kind: .to, to: firstMessage)
        addMessageParticipant(email: "first-list@example.com", kind: .to, to: firstMessage)
        addMessageParticipant(email: "first-cc@example.com", kind: .cc, to: firstMessage)

        let laterMessage = MessageBuilder()
            .withId("later-list-message")
            .withThreadId("thread-later")
            .withDate(Date(timeIntervalSince1970: 200))
            .withSender(email: "later-sender@example.com", name: "Later Sender")
            .withListId("list.example.com")
            .inConversation(conversation)
            .build(in: context)
        addMessageParticipant(email: "later-sender@example.com", kind: .from, to: laterMessage)
        addMessageParticipant(email: "me@example.com", kind: .to, to: laterMessage)
        addMessageParticipant(email: "later-list@example.com", kind: .to, to: laterMessage)
        addMessageParticipant(email: "later-cc@example.com", kind: .cc, to: laterMessage)
        addMessageParticipant(email: "later-bcc@example.com", kind: .bcc, to: laterMessage)

        var objects = Array(conversation.messages ?? []).map { $0 as NSManagedObject }
        objects.append(conversation)
        try context.obtainPermanentIDs(for: objects)
        return (conversation, laterMessage)
    }

    private func addConversationParticipant(
        email: String,
        displayName: String? = nil,
        to conversation: Conversation
    ) {
        let person = PersonBuilder()
            .withEmail(email)
            .withDisplayName(displayName)
            .build(in: viewContext)
        let participant = viewContext.insertTestObject(ConversationParticipant.self)
        participant.id = UUID()
        participant.person = person
        participant.participantRole = .normal
        participant.conversation = conversation
    }

    private var sendAsAliases: [SendAsAlias] {
        [
            SendAsAlias(
                emailAddress: "me@example.com",
                displayName: "Me",
                isDefault: true,
                isPrimary: true,
                verificationStatus: "accepted"
            ),
            SendAsAlias(
                emailAddress: "alias@example.com",
                displayName: "Alias",
                verificationStatus: "accepted"
            )
        ]
    }

    private func addMessageParticipant(
        person: Person,
        kind: ParticipantKind,
        to message: Message
    ) {
        let participant = viewContext.insertTestObject(MessageParticipant.self)
        participant.id = UUID()
        participant.participantKind = kind
        participant.person = person
        participant.message = message
    }

    private func addMessageParticipant(
        email: String,
        kind: ParticipantKind,
        to message: Message
    ) {
        let person = PersonBuilder()
            .withEmail(email)
            .noDisplayName()
            .build(in: viewContext)
        addMessageParticipant(person: person, kind: kind, to: message)
    }

    private func makeTestAuthSession(userEmail: String? = nil) -> AuthSession {
        let authSession = AuthSession(
            tokenManagerProvider: { MockTokenManager() },
            keychainService: MockKeychainService(),
            userDefaults: UserDefaults(suiteName: "OutboundReplyContextBuilderTests.\(UUID().uuidString)")!,
            clearConversationCaches: {},
            cleanupDownloads: {},
            resetCoreDataStore: {},
            clearAttachmentCache: {}
        )
        authSession.userEmail = userEmail
        return authSession
    }
}

private final class ReplyQuotedHTMLProbe: @unchecked Sendable {
    struct Snapshot {
        let callCount: Int
        let messageIDs: [String]
    }

    private let lock = NSLock()
    private let result: String?
    private var messageIDs: [String] = []

    init(result: String?) {
        self.result = result
    }

    var snapshot: Snapshot {
        lock.withLock {
            Snapshot(callCount: messageIDs.count, messageIDs: messageIDs)
        }
    }

    func load(_ source: ReplyQuotedHTMLSource) -> String? {
        lock.withLock {
            messageIDs.append(source.messageId)
            return result
        }
    }
}

@MainActor
private final class SuspendedUserAliasLoader {
    private var didStart = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var resultContinuation: CheckedContinuation<Set<String>, Never>?

    func load() async -> Set<String> {
        didStart = true
        startContinuation?.resume()
        startContinuation = nil
        return await withCheckedContinuation {
            resultContinuation = $0
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation {
            startContinuation = $0
        }
    }

    func resume(with aliases: Set<String> = []) {
        resultContinuation?.resume(returning: aliases)
        resultContinuation = nil
    }
}
