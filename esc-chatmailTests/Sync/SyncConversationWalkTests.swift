import XCTest
import CoreData
@testable import esc_chatmail

/// Writes on the sync path that used to walk every message of the
/// conversation they touched, for values the run's rollup then recomputed
/// (architecture review 2026-11, `sync-persist-path#2`, stage 1):
///
/// - a message leaving INBOX, on the update path
///   (`applyFastConversationListUpdateForExistingMessage`) and in history
///   label processing (`LabelOperationProcessor.applyFastInboxIndicators`);
/// - a send echo consumed in its own conversation
///   (`consumeRemoteCommittedSendMutation`).
///
/// Each now tracks the conversation and leaves `hasInbox`, `latestInboxDate`
/// and the rest to the rollup the run makes before the save. The store is
/// SQLite and each write runs in a context that has read nothing, as a sync
/// run's context does. What a walk leaves behind is its result: values the
/// conversation has before the rollup that only a walk could have computed.
final class SyncConversationWalkTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var persister: MessagePersister!

    private static let myEmail = "me@example.com"
    /// Oldest first; m-4 is the newest.
    private static let messageIDs = ["m-1", "m-2", "m-3", "m-4"]
    private static let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        try await super.setUp()
        stack = TestCoreDataStack(storeKind: .sqlite)
        persister = MessagePersister(
            coreDataStack: CoreDataStack(persistentContainerForTesting: stack.persistentContainer),
            saveHTML: { _, messageId in .savedWithoutWriting(messageId: messageId) },
            photoPrefetcher: { _ in }
        )
        await ModificationTracker.shared.reset()
    }

    override func tearDown() async throws {
        await ModificationTracker.shared.reset()
        persister = nil
        stack = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private static func date(ofMessageAt index: Int) -> Date {
        baseDate.addingTimeInterval(TimeInterval(index) * 60)
    }

    /// One conversation of four INBOX messages, saved. Returns its objectID.
    private func seedInboxConversation() throws -> NSManagedObjectID {
        let context = stack.newBackgroundContext()
        return try context.performAndWait {
            let inbox = LabelBuilder.inboxLabel(in: context)
            let conversation = ConversationBuilder()
                .withParticipantHash("p|walk")
                .hasInboxMessages(true)
                .visible()
                .build(in: context)
            for (index, id) in Self.messageIDs.enumerated() {
                let message = MessageBuilder()
                    .withId(id)
                    .withDate(Self.date(ofMessageAt: index))
                    .withSnippet("Message \(id)")
                    .inConversation(conversation)
                    .build(in: context)
                message.labels = [inbox]
            }
            conversation.lastMessageDate = Self.date(ofMessageAt: Self.messageIDs.count - 1)
            conversation.latestInboxDate = conversation.lastMessageDate
            try context.save()
            return conversation.objectID
        }
    }

    private func makeWriteContext() -> NSManagedObjectContext {
        let context = stack.newBackgroundContext()
        context.performAndWait {
            context.retainsRegisteredObjects = true
        }
        return context
    }

    /// The conversation's INBOX indicators as the write left them, before any
    /// rollup. The old walks recomputed them from every message at once; left
    /// to the rollup, they are what the conversation stored. Whether the write
    /// read the other messages cannot be asked of the context itself: the
    /// label write reads all of INBOX's members (the hub cost model 9 takes
    /// away), and measured with the old walk put back (iOS 27.0 simulator,
    /// 2026-11-28), `hasFault(forRelationshipNamed:)` answered true for the
    /// conversation's `messages` and the messages' `labels` after it had read
    /// them.
    private func inboxIndicators(
        _ conversationID: NSManagedObjectID,
        in context: NSManagedObjectContext
    ) async throws -> (hasInbox: Bool, latestInboxDate: Date?) {
        try await context.perform {
            let conversation = try XCTUnwrap(context.existingObject(with: conversationID) as? Conversation)
            return (conversation.hasInbox, conversation.latestInboxDate)
        }
    }

    /// The conversation's INBOX indicators after the run's rollup, made in
    /// `context` as the run's final save makes it.
    @MainActor
    private func inboxIndicatorsAfterRollup(
        _ conversationID: NSManagedObjectID,
        in context: NSManagedObjectContext
    ) async throws -> (hasInbox: Bool, latestInboxDate: Date?) {
        let updated = await ConversationRollupUpdater(
            coreDataStack: CoreDataStack(persistentContainerForTesting: stack.persistentContainer)
        ).updateRollupsForModified(conversationIDs: [conversationID], in: context, myEmail: Self.myEmail)
        XCTAssertTrue(updated)
        return try await inboxIndicators(conversationID, in: context)
    }

    // MARK: - A message leaves INBOX

    /// The newest message leaves INBOX on a refetch. The update moves only the
    /// unread count and tracks the conversation; the rollup moves
    /// `latestInboxDate` to the newest message still in INBOX.
    ///
    /// Revert-check: the `refreshConversationInboxIndicators` call removed from
    /// `applyFastConversationListUpdateForExistingMessage`. Put it back and the
    /// update walks the conversation and moves `latestInboxDate` itself.
    @MainActor
    func testUpdateLeavingInbox_leavesTheInboxIndicatorsToTheRollup() async throws {
        let conversationID = try seedInboxConversation()
        let context = makeWriteContext()
        let transaction = await ModificationTracker.shared.beginTransaction()
        let refetch = ProcessedMessage(
            id: "m-4",
            gmThreadId: "thread-walk",
            snippet: "Message m-4",
            cleanedSnippet: "Message m-4",
            internalDate: Self.date(ofMessageAt: 3),
            headers: ProcessedHeaders(),
            htmlBody: nil,
            plainTextBody: nil,
            labelIds: [],
            isUnread: false,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        let outcome = await persister.updateExistingMessageOutcome(
            refetch,
            labelIds: nil,
            myAliases: [Self.myEmail],
            modificationTransaction: transaction,
            reroutedSourceRollupBuffer: nil,
            remoteCommittedSendMutation: nil,
            in: context
        )

        XCTAssertEqual(outcome, .updated)
        let beforeRollup = try await inboxIndicators(conversationID, in: context)
        XCTAssertEqual(
            beforeRollup.latestInboxDate,
            Self.date(ofMessageAt: 3),
            "The update recomputed the conversation's INBOX indicators from its messages"
        )
        let tracked = await ModificationTracker.shared.modifiedConversations(in: transaction)
        XCTAssertEqual(tracked, [conversationID])
        let afterRollup = try await inboxIndicatorsAfterRollup(conversationID, in: context)
        XCTAssertTrue(afterRollup.hasInbox)
        XCTAssertEqual(afterRollup.latestInboxDate, Self.date(ofMessageAt: 2))
    }

    /// Gmail reports that the newest message left INBOX. The record moves
    /// only the unread count and returns the conversation for tracking; the
    /// rollup moves `latestInboxDate`.
    ///
    /// Revert-check: the `refreshInboxIndicators` call removed from
    /// `LabelOperationProcessor.applyFastInboxIndicators`. Put it back and the
    /// record walks the conversation and moves `latestInboxDate` itself.
    @MainActor
    func testHistoryInboxRemoval_leavesTheInboxIndicatorsToTheRollup() async throws {
        let conversationID = try seedInboxConversation()
        let context = makeWriteContext()
        let transaction = await ModificationTracker.shared.beginTransaction()

        try await HistoryProcessor(
            coreDataStack: CoreDataStack(persistentContainerForTesting: stack.persistentContainer)
        ).processLabelRemovals(
            [HistoryLabelRemoved(message: MessageListItem(id: "m-4", threadId: nil), labelIds: ["INBOX"])],
            in: context,
            syncStartTime: nil,
            modificationTransaction: transaction
        )

        let beforeRollup = try await inboxIndicators(conversationID, in: context)
        XCTAssertEqual(
            beforeRollup.latestInboxDate,
            Self.date(ofMessageAt: 3),
            "The record recomputed the conversation's INBOX indicators from its messages"
        )
        let tracked = await ModificationTracker.shared.modifiedConversations(in: transaction)
        XCTAssertEqual(tracked, [conversationID])
        let afterRollup = try await inboxIndicatorsAfterRollup(conversationID, in: context)
        XCTAssertTrue(afterRollup.hasInbox)
        XCTAssertEqual(afterRollup.latestInboxDate, Self.date(ofMessageAt: 2), "The newest message left INBOX")
    }

    // MARK: - A send echo

    private static func resolution(
        superseding optimisticObjectID: NSManagedObjectID
    ) -> MessagePersister.RemoteCommittedSendMutationResolution {
        MessagePersister.RemoteCommittedSendMutationResolution(
            recordObjectIDs: [],
            supersededOptimisticMessages: [
                optimisticObjectID: MessagePersister.SupersededOptimisticMessage(
                    optimisticMessageID: "local_optimistic",
                    newlyInsertedConversation: false
                )
            ],
            anchoredListConversationObjectID: nil,
            anchoredListId: nil,
            shouldConsumeAfterPersistence: true
        )
    }

    private func setStoredSnippet(_ snippet: String, of conversationID: NSManagedObjectID) throws {
        let context = stack.newBackgroundContext()
        try context.performAndWait {
            let conversation = try XCTUnwrap(context.existingObject(with: conversationID) as? Conversation)
            conversation.snippet = snippet
            try context.save()
        }
    }

    private func seedOptimisticRow(in conversationID: NSManagedObjectID) throws -> NSManagedObjectID {
        let context = stack.newBackgroundContext()
        return try context.performAndWait {
            let conversation = try XCTUnwrap(context.existingObject(with: conversationID) as? Conversation)
            let optimistic = MessageBuilder()
                .withId("local_optimistic")
                .withDate(Self.date(ofMessageAt: 10))
                .fromMe()
                .inConversation(conversation)
                .build(in: context)
            try context.save()
            return optimistic.objectID
        }
    }

    /// The echo's own conversation is rolled up by the run, which the caller
    /// tracks it for, so consuming the optimistic row there does not roll it
    /// up as well. The stored snippet is stale on purpose: a rollup would
    /// rewrite it, so it still being there says no rollup ran.
    ///
    /// Revert-check: the `persistedMessageConversationID` skip in
    /// `consumeRemoteCommittedSendMutation`. Without it the conversation is
    /// rolled up there too, over every remaining message, and the snippet is
    /// the newest message's.
    func testConsumingAnEchoInItsOwnConversation_leavesItsRollupToTheRun() async throws {
        let conversationID = try seedInboxConversation()
        let optimisticObjectID = try seedOptimisticRow(in: conversationID)
        try setStoredSnippet("A stale snippet", of: conversationID)
        let context = makeWriteContext()
        let persister = self.persister!

        let affected = await context.perform {
            persister.consumeRemoteCommittedSendMutation(
                Self.resolution(superseding: optimisticObjectID),
                persistedMessageConversationID: conversationID,
                in: context
            )
        }

        XCTAssertEqual(affected, [conversationID])
        let snippet = try await context.perform {
            try XCTUnwrap(context.existingObject(with: conversationID) as? Conversation).snippet
        }
        XCTAssertEqual(snippet, "A stale snippet", "Consuming the echo rolled up its own conversation")
        let optimisticIsDeleted = await context.perform {
            context.registeredObject(for: optimisticObjectID)?.isDeleted ?? false
        }
        XCTAssertTrue(optimisticIsDeleted)
    }

    /// A new echo whose optimistic row was in another conversation: that
    /// conversation is tracked for the run's rollup with the echo's own.
    ///
    /// Revert-check: `result.echoConversationIDs` in the create path's
    /// tracking (`MessagePersister.createNewMessage`). Track only the echo's
    /// conversation and the optimistic row's conversation is left to the
    /// consumption's own rollup, untracked.
    func testCreatingAnEchoWhoseOptimisticRowWasElsewhere_tracksThatConversationToo() async throws {
        let optimisticConversationID = try seedInboxConversation()
        let optimisticObjectID = try seedOptimisticRow(in: optimisticConversationID)
        let context = makeWriteContext()
        let transaction = await ModificationTracker.shared.beginTransaction()
        var headers = ProcessedHeaders()
        headers.from = "Me <\(Self.myEmail)>"
        headers.to = [EmailAddress(email: "alice@example.com", displayName: "Alice")]
        headers.isFromMe = true
        let echo = ProcessedMessage(
            id: "echo-remote-id",
            gmThreadId: "thread-echo",
            snippet: "Sent",
            cleanedSnippet: "Sent",
            internalDate: Self.date(ofMessageAt: 11),
            headers: headers,
            htmlBody: nil,
            plainTextBody: "Sent",
            labelIds: ["SENT"],
            isUnread: false,
            isNewsletter: false,
            hasAttachments: false,
            attachmentInfo: []
        )

        try await persister.createNewMessage(
            echo,
            labelIds: nil,
            myAliases: [Self.myEmail],
            modificationTransaction: transaction,
            remoteCommittedSendMutation: Self.resolution(superseding: optimisticObjectID),
            in: context
        )

        let echoConversationID = try await context.perform {
            let request = Message.fetchRequest()
            request.predicate = MessagePredicates.id("echo-remote-id")
            return try XCTUnwrap(try context.fetch(request).first?.conversation?.objectID)
        }
        XCTAssertNotEqual(echoConversationID, optimisticConversationID)
        let tracked = await ModificationTracker.shared.modifiedConversations(in: transaction)
        XCTAssertEqual(tracked, [echoConversationID, optimisticConversationID])
    }
}
