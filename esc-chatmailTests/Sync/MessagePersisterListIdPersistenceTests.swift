import XCTest
import CoreData
@testable import esc_chatmail

/// Pins normalized List-Id persistence and the bounded reroute performed when
/// a full refetch supplies List-Id for an existing participant-keyed row.
final class MessagePersisterListIdPersistenceTests: XCTestCase {
    private var stack: TestCoreDataStack!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
    }

    override func tearDown() {
        stack = nil
        super.tearDown()
    }

    func testCreatePersistsNormalizedListId() async throws {
        let syncContext = stack.newBackgroundContext()
        let persister = makePersister()

        try await persister.createNewMessage(
            makeArrival(listId: "Swift Evolution <Swift-Evolution.Swift.ORG>"),
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform { try syncContext.save() }

        let state = try XCTUnwrap(fetchDurableMessageState())
        XCTAssertEqual(state.listId, "swift-evolution.swift.org")
    }

    func testCreateLeavesListIdNilForNonListMail() async throws {
        let syncContext = stack.newBackgroundContext()
        let persister = makePersister()

        try await persister.createNewMessage(
            makeArrival(listId: nil),
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform { try syncContext.save() }

        let state = try XCTUnwrap(fetchDurableMessageState())
        XCTAssertNil(state.listId)
    }

    func testCreatePersistsRawReplyToHeader() async throws {
        let syncContext = stack.newBackgroundContext()
        let persister = makePersister()
        let rawReplyTo = #""octocat/Hello-World" <reply+123456@reply.github.com>, Swift Forums <forums@swift.org>"#

        try await persister.createNewMessage(
            makeArrival(
                listId: "<list.example.com>",
                replyTo: rawReplyTo
            ),
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform { try syncContext.save() }

        let state = try XCTUnwrap(fetchDurableMessageState())
        XCTAssertEqual(state.replyTo, rawReplyTo)
    }

    func testFullyRefetchedExistingMessagePersistsListIdAndReroutesToListConversation() async throws {
        let syncContext = stack.newBackgroundContext()
        let persister = makePersister()

        try await persister.createNewMessage(
            makeArrival(listId: nil),
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform { try syncContext.save() }
        try await syncContext.perform {
            let request = Conversation.fetchRequest()
            let source = try XCTUnwrap(try syncContext.fetch(request).first)
            source.pinned = true
            source.muted = true
            try syncContext.save()
        }

        let didUpdate = await persister.updateExistingMessage(
            makeArrival(listId: "<list.example.com>"),
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        XCTAssertTrue(didUpdate)
        try await syncContext.perform { try syncContext.save() }

        let state = try XCTUnwrap(fetchDurableMessageState())
        XCTAssertEqual(state.listId, "list.example.com")
        XCTAssertEqual(state.conversationListId, "list.example.com")
        XCTAssertEqual(state.conversationType, .list)
        XCTAssertEqual(
            state.conversationParticipantHash,
            calculateListConversationHash(fromNormalizedListId: "list.example.com")
        )
        XCTAssertEqual(state.conversationCount, 2)
        XCTAssertTrue(state.conversationPinned)
        XCTAssertTrue(state.conversationMuted)
        XCTAssertEqual(
            try fetchDurableConversationStates().first { $0.listId == nil }?.messageIDs,
            []
        )
    }

    func testHeaderlessUpdatePreservesStoredListId() async throws {
        let syncContext = stack.newBackgroundContext()
        let persister = makePersister()

        try await persister.createNewMessage(
            makeArrival(listId: "<list.example.com>"),
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform { try syncContext.save() }

        // A refetch that yields no List-Id header (metadata-only fetch, or the
        // provider dropping it) must not clear the stored grouping key.
        let didUpdate = await persister.updateExistingMessage(
            makeArrival(listId: nil),
            labelIds: ["INBOX"],
            in: syncContext
        )
        XCTAssertTrue(didUpdate)
        try await syncContext.perform { try syncContext.save() }

        let state = try XCTUnwrap(fetchDurableMessageState())
        XCTAssertEqual(state.listId, "list.example.com")
    }

    func testRemoteCommittedHeaderlessSentUpdateReroutesToAnchoredListAndConsumesRecordAtomically() async throws {
        let syncContext = stack.newBackgroundContext()
        let remoteMessageID = "remote-committed-list-update"
        let listId = "list.example.com"
        try await syncContext.perform {
            let listConversation = ConversationBuilder()
                .asList()
                .withListId(listId)
                .withParticipantHash(
                    calculateListConversationHash(fromNormalizedListId: listId)
                )
                .withDisplayName("Example List")
                .visible()
                .build(in: syncContext)
            let wrongConversation = ConversationBuilder()
                .withParticipantHash(
                    calculateParticipantHash(from: ["post@list.example.com"])
                )
                .withDisplayName("Wrong participant route")
                .withLastMessageDate(Date(timeIntervalSince1970: 200))
                .withSnippet("Sent list reply")
                .setPinned()
                .setMuted()
                .visible()
                .build(in: syncContext)
            _ = MessageBuilder()
                .withId(remoteMessageID)
                .withThreadId("remote-list-thread")
                .withDate(Date(timeIntervalSince1970: 200))
                .withSnippet("Sent list reply")
                .fromMe()
                .inConversation(wrongConversation)
                .build(in: syncContext)

            let record = syncContext.insertTestObject(
                OutboundSendMutationRecord.self
            )
            record.id = "optimistic-list-update"
            record.createdAt = Date(timeIntervalSince1970: 199)
            record.hidden = false
            record.newlyInsertedConversation = false
            record.conversationId = listConversation.id
            record.conversationURI =
                listConversation.objectID.uriRepresentation().absoluteString
            record.remoteCommittedMessageId = remoteMessageID
            record.remoteCommittedThreadId = "remote-list-thread"
            try syncContext.save()
        }

        let didUpdate = await makePersister().updateExistingMessage(
            makeHeaderlessSentArrival(id: remoteMessageID, date: 200),
            labelIds: ["SENT"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        XCTAssertTrue(didUpdate)

        // The old placement and route remain durable until the one save that
        // commits the move, inherited List-Id, rollup repair, and record delete.
        XCTAssertEqual(try durableMutationRecordCount(), 1)
        XCTAssertEqual(
            try fetchDurableConversationStates()
                .first { $0.listId == nil }?
                .messageIDs,
            [remoteMessageID]
        )

        try await syncContext.perform {
            try syncContext.save()
        }

        XCTAssertEqual(try durableMutationRecordCount(), 0)
        let state = try XCTUnwrap(fetchDurableMessageState())
        XCTAssertEqual(state.listId, listId)
        XCTAssertEqual(state.conversationListId, listId)
        XCTAssertTrue(state.conversationPinned)
        XCTAssertTrue(state.conversationMuted)
        let conversations = try fetchDurableConversationStates()
        XCTAssertEqual(
            conversations.first { $0.listId == listId }?.messageIDs,
            [remoteMessageID]
        )
        let source = try XCTUnwrap(conversations.first { $0.listId == nil })
        XCTAssertTrue(source.messageIDs.isEmpty)
        XCTAssertNil(source.lastMessageDate)
        XCTAssertNil(source.snippet)
    }

    func testRemoteCommittedHeaderlessSentAvoidsDrainedAnchorAndUsesReusableListReplacement() async throws {
        let syncContext = stack.newBackgroundContext()
        let remoteMessageID = "remote-committed-drained-list-anchor"
        let listId = "list.example.com"
        let conversationIDs = try await syncContext.perform { () throws -> (drained: UUID, replacement: UUID) in
            let drainedConversation = ConversationBuilder()
                .asList()
                .withListId(listId)
                .withParticipantHash(
                    calculateListConversationHash(fromNormalizedListId: listId)
                )
                .withDisplayName("Drained list epoch")
                .hasInboxMessages(false)
                .archived()
                .setHidden()
                .build(in: syncContext)
            let replacementConversation = ConversationBuilder()
                .asList()
                .withListId(listId)
                .withParticipantHash(
                    calculateListConversationHash(fromNormalizedListId: listId)
                )
                .withDisplayName("Reusable list epoch")
                .withLastMessageDate(Date(timeIntervalSince1970: 100))
                .visible()
                .build(in: syncContext)
            try syncContext.obtainPermanentIDs(for: [
                drainedConversation,
                replacementConversation
            ])

            let record = syncContext.insertTestObject(
                OutboundSendMutationRecord.self
            )
            record.id = "optimistic-drained-list-anchor"
            record.createdAt = Date(timeIntervalSince1970: 199)
            record.hidden = false
            record.newlyInsertedConversation = false
            record.conversationId = drainedConversation.id
            record.conversationURI =
                drainedConversation.objectID.uriRepresentation().absoluteString
            record.remoteCommittedMessageId = remoteMessageID
            record.remoteCommittedThreadId = "remote-list-thread"
            try syncContext.save()

            return (drainedConversation.id, replacementConversation.id)
        }

        try await makePersister().createNewMessage(
            makeHeaderlessSentArrival(id: remoteMessageID, date: 200),
            labelIds: ["SENT"],
            myAliases: ["me@example.com"],
            in: syncContext
        )

        // The durable route remains until the replacement relationship,
        // inherited List-Id, and record deletion cross one save together.
        XCTAssertEqual(try durableMutationRecordCount(), 1)

        try await syncContext.perform {
            try syncContext.save()
        }

        XCTAssertEqual(try durableMutationRecordCount(), 0)
        let state = try XCTUnwrap(fetchDurableMessageState())
        XCTAssertEqual(state.listId, listId)
        XCTAssertEqual(state.conversationListId, listId)

        let conversations = try fetchDurableConversationStates()
        let drained = try XCTUnwrap(
            conversations.first { $0.id == conversationIDs.drained }
        )
        XCTAssertTrue(drained.messageIDs.isEmpty)
        XCTAssertTrue(drained.hidden)
        XCTAssertNotNil(drained.archivedAt)
        XCTAssertNil(drained.lastMessageDate)
        XCTAssertEqual(
            conversations.first { $0.id == conversationIDs.replacement }?.messageIDs,
            [remoteMessageID]
        )
    }

    func testReplyToOmittedByRefetchPreservesStoredRawHeader() async throws {
        let syncContext = stack.newBackgroundContext()
        let persister = makePersister()
        let rawReplyTo = #"GitHub <reply+123456@reply.github.com>"#

        try await persister.createNewMessage(
            makeArrival(
                listId: "<list.example.com>",
                replyTo: rawReplyTo
            ),
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform { try syncContext.save() }

        let didUpdate = await persister.updateExistingMessage(
            makeArrival(
                listId: "<list.example.com>",
                replyTo: nil
            ),
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        XCTAssertTrue(didUpdate)
        try await syncContext.perform { try syncContext.save() }

        let state = try XCTUnwrap(fetchDurableMessageState())
        XCTAssertEqual(state.replyTo, rawReplyTo)
    }

    func testFullyRefetchedListMessageMovesWithoutDrainingMixedSourceConversation() async throws {
        let syncContext = stack.newBackgroundContext()
        try seedSystemLabels(in: syncContext)
        let persister = makePersister()

        try await persister.createNewMessage(
            makeArrival(id: "message-to-reroute", listId: nil, date: 200, isUnread: true),
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform { try syncContext.save() }
        try await persister.createNewMessage(
            makeArrival(id: "message-that-stays", listId: nil, date: 100, isUnread: true),
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform { try syncContext.save() }

        let didUpdate = await persister.updateExistingMessage(
            makeArrival(
                id: "message-to-reroute",
                listId: "<list.example.com>",
                date: 200,
                isUnread: true
            ),
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        XCTAssertTrue(didUpdate)
        try await syncContext.perform { try syncContext.save() }

        let states = try fetchDurableConversationStates()
        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(
            states.first { $0.listId == "list.example.com" }?.messageIDs,
            ["message-to-reroute"]
        )
        XCTAssertEqual(
            states.first { $0.listId == nil }?.messageIDs,
            ["message-that-stays"]
        )
        let source = try XCTUnwrap(states.first { $0.listId == nil })
        XCTAssertEqual(source.lastMessageDate, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(source.snippet, "List post body")
        XCTAssertTrue(source.hasInbox)
        XCTAssertEqual(source.inboxUnreadCount, 1)
        XCTAssertEqual(source.latestInboxDate, Date(timeIntervalSince1970: 100))
    }

    func testSaveMessagesRefreshesSharedRerouteSourceAfterAllMoves() async throws {
        let syncContext = stack.newBackgroundContext()
        try seedSystemLabels(in: syncContext)
        let seedPersister = makePersister()
        let legacyMessages = [
            makeArrival(id: "reroute-older", listId: nil, date: 100, isUnread: true),
            makeArrival(id: "source-remains", listId: nil, date: 200, isUnread: true),
            makeArrival(id: "reroute-newer", listId: nil, date: 300, isUnread: true)
        ]

        for message in legacyMessages {
            try await seedPersister.createNewMessage(
                message,
                labelIds: ["INBOX", "UNREAD"],
                myAliases: ["me@example.com"],
                in: syncContext
            )
        }
        try await syncContext.perform { try syncContext.save() }

        let reroutedMessages = [
            makeArrival(
                id: "reroute-older",
                listId: "<list.example.com>",
                date: 100,
                isUnread: true
            ),
            makeArrival(
                id: "reroute-newer",
                listId: "<list.example.com>",
                date: 300,
                isUnread: true
            )
        ]
        let batchPersister = MessagePersister(
            messageProcessor: BatchStubMessageProcessor(messages: reroutedMessages),
            photoPrefetcher: { _ in }
        )
        let gmailMessages = reroutedMessages.map {
            GmailMessage(
                id: $0.id,
                threadId: $0.gmThreadId,
                labelIds: $0.labelIds,
                snippet: $0.snippet,
                historyId: nil,
                internalDate: nil,
                payload: nil,
                sizeEstimate: nil
            )
        }
        let modificationTransaction = await ModificationTracker.shared.beginTransaction()

        try await batchPersister.saveMessages(
            gmailMessages,
            labelIds: ["INBOX", "UNREAD"],
            myAliases: ["me@example.com"],
            modificationTransaction: modificationTransaction,
            in: syncContext
        )

        let movedConversationIDs: Set<NSManagedObjectID> = try await syncContext.perform {
            let request = Conversation.fetchRequest()
            request.relationshipKeyPathsForPrefetching = ["messages", "messages.labels"]
            let conversations = try syncContext.fetch(request)
            let source = try XCTUnwrap(conversations.first { $0.listId == nil })
            let destination = try XCTUnwrap(
                conversations.first { $0.listId == "list.example.com" }
            )
            XCTAssertEqual(Set((source.messages ?? []).map(\.id)), ["source-remains"])
            XCTAssertEqual(source.lastMessageDate, Date(timeIntervalSince1970: 200))
            XCTAssertEqual(source.snippet, "List post body")
            XCTAssertTrue(source.hasInbox)
            XCTAssertEqual(source.inboxUnreadCount, 1)
            XCTAssertEqual(source.latestInboxDate, Date(timeIntervalSince1970: 200))
            try syncContext.save()
            return [source.objectID, destination.objectID]
        }
        let trackedConversationIDs = await ModificationTracker.shared.modifiedConversations(
            in: modificationTransaction
        )
        XCTAssertEqual(trackedConversationIDs, movedConversationIDs)
        await ModificationTracker.shared.rollbackTransaction(modificationTransaction)

        let states = try fetchDurableConversationStates()
        XCTAssertEqual(
            states.first { $0.listId == nil }?.messageIDs,
            ["source-remains"]
        )
        XCTAssertEqual(
            states.first { $0.listId == "list.example.com" }?.messageIDs,
            ["reroute-older", "reroute-newer"]
        )
    }

    func testSaveMessagesCommitsRerouteAndRepairedSourceRollupTogether() async throws {
        let syncContext = stack.newBackgroundContext()
        try seedSystemLabels(in: syncContext)
        let seedPersister = makePersister()

        for message in [
            makeArrival(id: "source-remains-before-save", listId: nil, date: 100, isUnread: true),
            makeArrival(id: "reroute-before-save", listId: nil, date: 200, isUnread: true)
        ] {
            try await seedPersister.createNewMessage(
                message,
                labelIds: ["INBOX", "UNREAD"],
                myAliases: ["me@example.com"],
                in: syncContext
            )
        }
        try await syncContext.perform { try syncContext.save() }
        let sourceID = try await syncContext.perform {
            let source = try XCTUnwrap(try syncContext.fetch(Conversation.fetchRequest()).first)
            return source.id
        }

        let reroutedMessage = makeArrival(
            id: "reroute-before-save",
            listId: "<list.example.com>",
            date: 200,
            isUnread: true
        )
        var newConversationMessage = makeArrival(
            id: "new-conversation-message",
            listId: nil,
            date: 300,
            isUnread: true
        )
        newConversationMessage.gmThreadId = "new-conversation-thread"
        newConversationMessage.headers.from = "Other Sender <other@example.com>"
        let batchMessages = [reroutedMessage, newConversationMessage]
        let batchPersister = MessagePersister(
            messageProcessor: BatchStubMessageProcessor(messages: batchMessages),
            photoPrefetcher: { _ in }
        )

        try await batchPersister.saveMessages(
            batchMessages.map {
                GmailMessage(
                    id: $0.id,
                    threadId: $0.gmThreadId,
                    labelIds: $0.labelIds,
                    snippet: $0.snippet,
                    historyId: nil,
                    internalDate: nil,
                    payload: nil,
                    sizeEstimate: nil
                )
            },
            labelIds: ["INBOX", "UNREAD"],
            myAliases: ["me@example.com"],
            in: syncContext
        )

        // Before the caller's save, the reroute and its repaired source
        // rollup are pending caller-context state: only the new conversation
        // SHELLS are durable (the serializer commits shells in its own
        // context and no longer saves the caller's context mid-batch).
        let durableBeforeSave = try fetchDurableConversationStates()
        let durableSourceBefore = try XCTUnwrap(durableBeforeSave.first { $0.id == sourceID })
        XCTAssertEqual(
            Set(durableSourceBefore.messageIDs),
            ["source-remains-before-save", "reroute-before-save"],
            "The move must not be durable until the caller's save"
        )
        XCTAssertEqual(
            durableBeforeSave.first { $0.listId == "list.example.com" }?.messageIDs,
            [],
            "The list shell publishes empty; its message rides the batch save"
        )
        XCTAssertTrue(
            durableBeforeSave.contains {
                $0.id != sourceID &&
                    $0.listId == nil &&
                    $0.messageIDs.isEmpty &&
                    $0.lastMessageDate == Date(timeIntervalSince1970: 300)
            },
            "The new participant conversation publishes as a seeded empty shell"
        )

        // The caller's save is the durability boundary where the move and its
        // repaired source rollup land together.
        try await syncContext.perform { try syncContext.save() }

        let durableStates = try fetchDurableConversationStates()
        let durableSource = try XCTUnwrap(durableStates.first { $0.id == sourceID })
        XCTAssertEqual(durableSource.messageIDs, ["source-remains-before-save"])
        XCTAssertEqual(durableSource.lastMessageDate, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(durableSource.snippet, "List post body")
        XCTAssertTrue(durableSource.hasInbox)
        XCTAssertEqual(durableSource.inboxUnreadCount, 1)
        XCTAssertEqual(durableSource.latestInboxDate, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(
            durableStates.first { $0.listId == "list.example.com" }?.messageIDs,
            ["reroute-before-save"]
        )
        XCTAssertTrue(
            durableStates.contains {
                $0.id != sourceID &&
                    $0.listId == nil &&
                    $0.messageIDs == ["new-conversation-message"] &&
                    $0.lastMessageDate == Date(timeIntervalSince1970: 300)
            },
            "The batch save lands the new conversation's message alongside the reroute"
        )
    }

    func testFullyRefetchedListMessageRetainsDrainedSourceAsHiddenEmptyShell() async throws {
        let syncContext = stack.newBackgroundContext()
        let persister = makePersister()

        try await persister.createNewMessage(
            makeArrival(listId: nil),
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform { try syncContext.save() }
        let sourceID = try await syncContext.perform {
            let source = try XCTUnwrap(try syncContext.fetch(Conversation.fetchRequest()).first)
            return source.id
        }

        let didUpdate = await persister.updateExistingMessage(
            makeArrival(listId: "<list.example.com>"),
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        XCTAssertTrue(didUpdate)
        try await syncContext.perform { try syncContext.save() }

        let states = try fetchDurableConversationStates()
        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(
            states.first { $0.id == sourceID }?.messageIDs,
            []
        )
        let source = try XCTUnwrap(states.first { $0.id == sourceID })
        XCTAssertNil(source.lastMessageDate)
        XCTAssertNil(source.snippet)
        XCTAssertFalse(source.hasInbox)
        XCTAssertEqual(source.inboxUnreadCount, 0)
        XCTAssertNil(source.latestInboxDate)
        XCTAssertNotNil(source.archivedAt)
        XCTAssertTrue(source.hidden)
        XCTAssertEqual(
            states.first { $0.listId == "list.example.com" }?.messageIDs,
            ["msg-list-id"]
        )
    }

    func testExistingNonInboxListRefetchReusesArchivedEpochWithoutReactivation() async throws {
        let syncContext = stack.newBackgroundContext()
        let persister = makePersister()
        let archivedAt = Date(timeIntervalSince1970: 500)

        try await persister.createNewMessage(
            makeArrival(
                id: "existing-list-message",
                listId: "<list.example.com>",
                date: 100,
                messageLabelIDs: []
            ),
            labelIds: [],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform {
            let listConversation = try XCTUnwrap(
                try syncContext.fetch(Conversation.fetchRequest()).first { $0.listId == "list.example.com" }
            )
            listConversation.archivedAt = archivedAt
            listConversation.hidden = true
            try syncContext.save()
        }

        try await persister.createNewMessage(
            makeArrival(
                id: "legacy-message",
                listId: nil,
                date: 200,
                messageLabelIDs: []
            ),
            labelIds: [],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform { try syncContext.save() }

        let didUpdate = await persister.updateExistingMessage(
            makeArrival(
                id: "legacy-message",
                listId: "<list.example.com>",
                date: 200,
                messageLabelIDs: []
            ),
            labelIds: [],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        XCTAssertTrue(didUpdate)
        try await syncContext.perform { try syncContext.save() }

        try await persister.createNewMessage(
            makeArrival(
                id: "second-legacy-message",
                listId: nil,
                date: 300,
                messageLabelIDs: []
            ),
            labelIds: [],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform { try syncContext.save() }
        let didUpdateSecondLegacyMessage = await persister.updateExistingMessage(
            makeArrival(
                id: "second-legacy-message",
                listId: "<list.example.com>",
                date: 300,
                messageLabelIDs: []
            ),
            labelIds: [],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        XCTAssertTrue(didUpdateSecondLegacyMessage)
        try await syncContext.perform { try syncContext.save() }

        let states = try fetchDurableConversationStates()
        let listConversations = states.filter { $0.listId == "list.example.com" }
        XCTAssertEqual(listConversations.count, 1)
        XCTAssertEqual(
            listConversations.first?.messageIDs,
            ["existing-list-message", "legacy-message", "second-legacy-message"]
        )
        XCTAssertEqual(listConversations.first?.archivedAt, archivedAt)
        XCTAssertTrue(listConversations.first?.hidden ?? false)
    }

    func testListDestinationResolutionFailureDoesNotPersistSplitIdentity() async throws {
        let syncContext = stack.newBackgroundContext()
        let seedPersister = makePersister()
        try await seedPersister.createNewMessage(
            makeArrival(listId: nil),
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform { try syncContext.save() }

        let failingConversationManager = ConversationManager(
            findOrCreateConversationHandler: { _, _, _, _, _, _ in
                throw TestRoutingError.expectedFailure
            }
        )
        let failingPersister = MessagePersister(
            conversationManager: failingConversationManager,
            conversationRouter: MessageConversationRouter(
                conversationManager: failingConversationManager
            ),
            photoPrefetcher: { _ in }
        )

        let didUpdate = await failingPersister.updateExistingMessage(
            makeArrival(listId: "<list.example.com>"),
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        XCTAssertTrue(didUpdate)
        try await syncContext.perform { try syncContext.save() }

        let state = try XCTUnwrap(fetchDurableMessageState())
        XCTAssertNil(state.listId)
        XCTAssertNil(state.conversationListId)
        XCTAssertEqual(state.conversationCount, 1)
    }

    // MARK: - Helpers

    private func makePersister() -> MessagePersister {
        MessagePersister(photoPrefetcher: { _ in })
    }

    private struct DurableMessageState {
        let listId: String?
        let replyTo: String?
        let conversationListId: String?
        let conversationType: ConversationType?
        let conversationParticipantHash: String?
        let conversationPinned: Bool
        let conversationMuted: Bool
        let conversationCount: Int
    }

    private struct DurableConversationState {
        let id: UUID
        let listId: String?
        let messageIDs: Set<String>
        let lastMessageDate: Date?
        let snippet: String?
        let hasInbox: Bool
        let inboxUnreadCount: Int32
        let latestInboxDate: Date?
        let archivedAt: Date?
        let hidden: Bool
    }

    private enum TestRoutingError: Error {
        case expectedFailure
    }

    private func fetchDurableMessageState() throws -> DurableMessageState? {
        let verificationContext = stack.newBackgroundContext()
        return try verificationContext.performAndWait {
            let request = Message.fetchRequest()
            request.fetchLimit = 1
            request.relationshipKeyPathsForPrefetching = ["conversation"]
            guard let message = try verificationContext.fetch(request).first else {
                return nil
            }
            let conversationCount = try verificationContext.count(for: Conversation.fetchRequest())
            return DurableMessageState(
                listId: message.listId,
                replyTo: message.replyTo,
                conversationListId: message.conversation?.listId,
                conversationType: message.conversation?.conversationType,
                conversationParticipantHash: message.conversation?.participantHash,
                conversationPinned: message.conversation?.pinned ?? false,
                conversationMuted: message.conversation?.muted ?? false,
                conversationCount: conversationCount
            )
        }
    }

    private func fetchDurableConversationStates() throws -> [DurableConversationState] {
        let verificationContext = stack.newBackgroundContext()
        return try verificationContext.performAndWait {
            let request = Conversation.fetchRequest()
            request.relationshipKeyPathsForPrefetching = ["messages"]
            return try verificationContext.fetch(request).map {
                DurableConversationState(
                    id: $0.id,
                    listId: $0.listId,
                    messageIDs: Set(($0.messages ?? []).map(\.id)),
                    lastMessageDate: $0.lastMessageDate,
                    snippet: $0.snippet,
                    hasInbox: $0.hasInbox,
                    inboxUnreadCount: $0.inboxUnreadCount,
                    latestInboxDate: $0.latestInboxDate,
                    archivedAt: $0.archivedAt,
                    hidden: $0.hidden
                )
            }
        }
    }

    private func durableMutationRecordCount() throws -> Int {
        let verificationContext = stack.newBackgroundContext()
        return try verificationContext.performAndWait {
            let request = OutboundSendMutationRecord.fetchRequest()
            request.includesPendingChanges = false
            return try verificationContext.count(for: request)
        }
    }

    private func makeArrival(
        id: String = "msg-list-id",
        listId: String?,
        replyTo: String? = nil,
        date: TimeInterval = 1_700_000_000,
        isUnread: Bool = false,
        messageLabelIDs: [String] = ["INBOX"]
    ) -> ProcessedMessage {
        var headers = ProcessedHeaders()
        headers.subject = "List post"
        headers.from = "Sender <sender@example.com>"
        headers.to = [EmailAddress(email: "me@example.com", displayName: nil)]
        headers.isFromMe = false
        headers.listId = listId
        headers.replyTo = replyTo

        var processed = ProcessedMessage()
        processed.id = id
        processed.gmThreadId = "thread-list-id"
        processed.snippet = "List post body"
        processed.cleanedSnippet = "List post body"
        processed.chatPreviewText = "List post body"
        processed.internalDate = Date(timeIntervalSince1970: date)
        processed.headers = headers
        processed.plainTextBody = "List post body"
        processed.labelIds = messageLabelIDs
        processed.isUnread = isUnread
        return processed
    }

    private func makeHeaderlessSentArrival(
        id: String,
        date: TimeInterval
    ) -> ProcessedMessage {
        var processed = makeArrival(
            id: id,
            listId: nil,
            date: date,
            messageLabelIDs: ["SENT"]
        )
        processed.gmThreadId = "remote-list-thread"
        processed.headers.from = "Me <me@example.com>"
        processed.headers.to = [
            EmailAddress(email: "post@list.example.com", displayName: nil)
        ]
        processed.headers.isFromMe = true
        processed.snippet = "Sent list reply"
        processed.cleanedSnippet = "Sent list reply"
        processed.chatPreviewText = "Sent list reply"
        processed.plainTextBody = "Sent list reply"
        return processed
    }

    private func seedSystemLabels(in context: NSManagedObjectContext) throws {
        try context.performAndWait {
            LabelBuilder().inbox().build(in: context)
            LabelBuilder().unread().build(in: context)
            try context.save()
        }
    }
}

private final class BatchStubMessageProcessor: MessageProcessor, @unchecked Sendable {
    private let messagesByID: [String: ProcessedMessage]

    init(messages: [ProcessedMessage]) {
        messagesByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
    }

    override func processGmailMessage(
        _ gmailMessage: GmailMessage,
        myAliases: Set<String>,
        sendAsAliases: [SendAsAlias] = []
    ) async -> ProcessedMessage? {
        messagesByID[gmailMessage.id]
    }
}
