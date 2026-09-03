import XCTest
import CoreData
@testable import esc_chatmail

@MainActor
final class OutboundReplyContextBuilderTests: XCTestCase {
    private var coreDataStack: TestCoreDataStack!
    private var htmlContentHandler: HTMLContentHandler!

    override func setUp() {
        super.setUp()
        coreDataStack = TestCoreDataStack()
        htmlContentHandler = HTMLContentHandler()
    }

    override func tearDown() {
        htmlContentHandler = nil
        coreDataStack = nil
        super.tearDown()
    }

    func testBuild_createsStableReplyRequestContextAndConversationAnchor() throws {
        let context = coreDataStack.viewContext
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
        let context = coreDataStack.viewContext
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

    func testBuildReplyMetadata_defersOriginalHTMLResolution() async throws {
        let context = coreDataStack.viewContext
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
        let context = coreDataStack.viewContext
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

        try coreDataStack.saveViewContext()
        let conversationID = conversation.objectID
        let replyingToID = replyingTo.objectID
        coreDataStack.resetViewContext()
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
        let context = coreDataStack.viewContext
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
        try coreDataStack.saveViewContext()

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
        let context = coreDataStack.viewContext
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
        let context = coreDataStack.viewContext
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
        let context = coreDataStack.viewContext
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
        let context = coreDataStack.viewContext
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
        for emptyThread in ["", " \n "] {
            localMessage.gmThreadId = emptyThread
            let metadata = try await builder.buildReplyMetadata(replyContext)
            XCTAssertEqual(metadata.threadId, "server-thread")
        }
    }

    func testBuildReplyMetadata_backfillsReplyFromAliasFromLegacyTargetParticipants() async throws {
        let context = coreDataStack.viewContext
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
        let context = coreDataStack.viewContext
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
            .build(in: coreDataStack.viewContext)
        addMessageParticipant(email: "newest-sender@example.com", kind: .from, to: newestMatchingMessage)
        addMessageParticipant(email: "me@example.com", kind: .to, to: newestMatchingMessage)
        addMessageParticipant(email: "newest-list@example.com", kind: .to, to: newestMatchingMessage)
        try coreDataStack.viewContext.obtainPermanentIDs(for: [newestMatchingMessage])

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

    func testBuildReplyMetadata_listReplyToReconciledOptimisticMessageFallsBackToLatestInboundRecipients() async throws {
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
            .build(in: coreDataStack.viewContext)
        reconciledOptimisticMessage.messageId = "<optimistic@example.com>"
        try coreDataStack.viewContext.obtainPermanentIDs(for: [reconciledOptimisticMessage])

        let metadata = try await makeBuilder(userEmail: "me@example.com").buildReplyMetadata(
            .init(
                conversationObjectID: fixture.conversation.objectID,
                replyingToMessageObjectID: reconciledOptimisticMessage.objectID,
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
            .build(in: coreDataStack.viewContext)
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
            .build(in: coreDataStack.viewContext)
        addMessageParticipant(email: "me@example.com", kind: .from, to: latestOutbound)
        addMessageParticipant(email: "outbound-only@example.com", kind: .to, to: latestOutbound)
        try coreDataStack.viewContext.obtainPermanentIDs(
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
        let context = coreDataStack.viewContext
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
        let context = coreDataStack.viewContext
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
            .build(in: coreDataStack.viewContext)
        try coreDataStack.viewContext.obtainPermanentIDs(for: [otherConversation])
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
        let context = coreDataStack.viewContext
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
            XCTFail("Expected replyTargetUnavailable")
        } catch {
            guard case GmailSendService.SendError.replyTargetUnavailable = error else {
                return XCTFail("Expected replyTargetUnavailable, got \(error)")
            }
        }
    }

    private func makeBuilder(
        userEmail: String = "me@example.com",
        userAliases: Set<String> = [],
        replyQuotedHTMLResolver: ReplyQuotedHTMLResolver? = nil,
        loadUserAliases: (@MainActor () async -> Set<String>)? = nil
    ) -> OutboundReplyContextBuilder {
        OutboundReplyContextBuilder(
            viewContext: coreDataStack.viewContext,
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

    private func makeRotatingListConversation() throws -> (
        conversation: Conversation,
        laterMessage: Message
    ) {
        let context = coreDataStack.viewContext
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
        to conversation: Conversation
    ) {
        let person = PersonBuilder()
            .withEmail(email)
            .noDisplayName()
            .build(in: coreDataStack.viewContext)
        let participant = coreDataStack.viewContext.insertTestObject(ConversationParticipant.self)
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
        let participant = coreDataStack.viewContext.insertTestObject(MessageParticipant.self)
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
            .build(in: coreDataStack.viewContext)
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
