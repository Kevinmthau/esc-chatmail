import XCTest
import CoreData
@testable import esc_chatmail

/// Pins the durable unread state for a brand-new conversation created by an
/// incoming unread INBOX message.
///
/// The conversation shell is saved by `ConversationCreationSerializer` before
/// the message row exists, and that save is what the view context's
/// insert-merge publishes to the chat list. If the shell carries a snippet and
/// date but no unread indicators, the list renders a previewed row with no
/// blue dot until a later rollup save merges.
final class MessagePersisterNewConversationUnreadTests: XCTestCase {
    private var stack: TestCoreDataStack!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
    }

    override func tearDown() {
        stack = nil
        super.tearDown()
    }

    func testFirstDurableSaveCarriesUnreadIndicatorsForNewUnreadInboxArrival() async throws {
        let syncContext = stack.newBackgroundContext()
        try seedSystemLabels(in: syncContext)
        let persister = makePersister()

        try await persister.createNewMessage(
            makeUnreadInboxArrival(),
            labelIds: ["INBOX", "UNREAD"],
            myAliases: ["me@example.com"],
            in: syncContext
        )

        // The sync context is deliberately NOT saved: the only durable state is
        // the conversation shell the creation serializer saved — exactly the row
        // the view context's insert-merge publishes to the chat list.
        let persisted = try XCTUnwrap(fetchDurableConversationRow())
        XCTAssertNotNil(persisted.snippet, "shell save already seeds the row preview")
        XCTAssertNotNil(persisted.lastMessageDate, "shell save already seeds the row timestamp")
        XCTAssertEqual(persisted.inboxUnreadCount, 1, "a previewed row must also carry its unread dot")
        XCTAssertTrue(persisted.hasInbox)
        XCTAssertEqual(persisted.latestInboxDate, Self.arrivalDate)
    }

    func testRollupRecomputeSavePreservesSeededUnreadCount() async throws {
        let syncContext = stack.newBackgroundContext()
        try seedSystemLabels(in: syncContext)
        let persister = makePersister()

        try await persister.createNewMessage(
            makeUnreadInboxArrival(),
            labelIds: ["INBOX", "UNREAD"],
            myAliases: ["me@example.com"],
            in: syncContext
        )

        try await recomputeRollupsAndSave(in: syncContext)

        let persisted = try XCTUnwrap(fetchDurableConversationRow())
        XCTAssertEqual(persisted.inboxUnreadCount, 1)
        XCTAssertTrue(persisted.hasInbox)
    }

    func testEmptyPrefetchedLabelCacheDoesNotStripLabelsOnCreation() async throws {
        let syncContext = stack.newBackgroundContext()
        try seedSystemLabels(in: syncContext)
        let persister = makePersister()

        // An empty (non-nil) prefetched label set models a failed label
        // prefetch. It must fall back to the message's raw labelIds instead
        // of stripping every label relationship, or the rollup recompute
        // (which counts via the relationship) persists a durable zero.
        try await persister.createNewMessage(
            makeUnreadInboxArrival(),
            labelIds: [],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform {
            try syncContext.save()
        }

        try await recomputeRollupsAndSave(in: syncContext)

        let persisted = try XCTUnwrap(fetchDurableConversationRow())
        XCTAssertEqual(persisted.inboxUnreadCount, 1)
        XCTAssertTrue(persisted.hasInbox)
    }

    func testEmptyPrefetchedLabelCacheDoesNotStripLabelsOnUpdate() async throws {
        let syncContext = stack.newBackgroundContext()
        try seedSystemLabels(in: syncContext)
        let persister = makePersister()

        try await persister.createNewMessage(
            makeUnreadInboxArrival(),
            labelIds: ["INBOX", "UNREAD"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform {
            try syncContext.save()
        }

        // Re-sync the same message with a failed (empty) label prefetch: the
        // update path rebuilds the label relationships and must not strip them.
        let didUpdate = await persister.updateExistingMessage(
            makeUnreadInboxArrival(),
            labelIds: [],
            in: syncContext
        )
        XCTAssertTrue(didUpdate)
        try await syncContext.perform {
            try syncContext.save()
        }

        try await recomputeRollupsAndSave(in: syncContext)

        let persisted = try XCTUnwrap(fetchDurableConversationRow())
        XCTAssertEqual(persisted.inboxUnreadCount, 1)
        XCTAssertTrue(persisted.hasInbox)
    }

    func testSecondArrivalInExistingThreadDoesNotDisturbDurableUnreadCount() async throws {
        let syncContext = stack.newBackgroundContext()
        try seedSystemLabels(in: syncContext)
        let persister = makePersister()

        try await persister.createNewMessage(
            makeUnreadInboxArrival(id: "msg-first"),
            labelIds: ["INBOX", "UNREAD"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform {
            try syncContext.save()
        }
        XCTAssertEqual(try XCTUnwrap(fetchDurableConversationRow()).inboxUnreadCount, 1)

        // A second arrival in the same thread reuses the conversation: no shell
        // save runs, so the durable count must be untouched until the sync save.
        try await persister.createNewMessage(
            makeUnreadInboxArrival(id: "msg-second"),
            labelIds: ["INBOX", "UNREAD"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        XCTAssertEqual(try XCTUnwrap(fetchDurableConversationRow()).inboxUnreadCount, 1)

        try await syncContext.perform {
            try syncContext.save()
        }
        XCTAssertEqual(try XCTUnwrap(fetchDurableConversationRow()).inboxUnreadCount, 2)
    }

    func testSerializerSeedsInboxIndicatorsInImmediateSave() async throws {
        let identity = makeConversationIdentity(
            from: [
                MessageHeader(name: "From", value: "Daisy Wong <daisy@example.com>"),
                MessageHeader(name: "To", value: "me@example.com")
            ],
            gmThreadId: "thread-inbox-seed",
            myAliases: ["me@example.com"]
        )
        let context = stack.newBackgroundContext()

        let objectID = try await ConversationCreationSerializer.shared.findOrCreateConversationObjectID(
            for: identity,
            initialLastMessageDate: Self.arrivalDate,
            initialSnippet: "Hello there",
            initialInboxSeed: ConversationInboxSeed(
                isInboxArrival: true,
                isUnread: true,
                messageDate: Self.arrivalDate
            ),
            in: context
        )

        // Read through a separate context so only the serializer's own save counts.
        let verificationContext = stack.newBackgroundContext()
        let row: (unread: Int32, hasInbox: Bool, latestInboxDate: Date?)? = await verificationContext.perform {
            guard let conversation = try? verificationContext.existingObject(with: objectID) as? Conversation else {
                return nil
            }
            return (conversation.inboxUnreadCount, conversation.hasInbox, conversation.latestInboxDate)
        }

        let persisted = try XCTUnwrap(row)
        XCTAssertEqual(persisted.unread, 1)
        XCTAssertTrue(persisted.hasInbox)
        XCTAssertEqual(persisted.latestInboxDate, Self.arrivalDate)
    }

    // MARK: - Helpers

    private static let arrivalDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makePersister() -> MessagePersister {
        MessagePersister(photoPrefetcher: { _ in })
    }

    private func makeUnreadInboxArrival(id: String = "msg-new-unread") -> ProcessedMessage {
        var headers = ProcessedHeaders()
        headers.subject = "Hello"
        headers.from = "Daisy Wong <daisy@example.com>"
        headers.to = [EmailAddress(email: "me@example.com", displayName: nil)]
        headers.isFromMe = false

        var processed = ProcessedMessage()
        processed.id = id
        processed.gmThreadId = "thread-new-unread"
        processed.snippet = "Hello there"
        processed.cleanedSnippet = "Hello there"
        processed.chatPreviewText = "Hello there"
        processed.internalDate = Self.arrivalDate
        processed.headers = headers
        processed.plainTextBody = "Hello there"
        processed.labelIds = ["INBOX", "UNREAD"]
        processed.isUnread = true
        return processed
    }

    /// Mirrors the orchestrator's flush block: serialized rollup recompute + save.
    private func recomputeRollupsAndSave(in syncContext: NSManagedObjectContext) async throws {
        let fetchedConversationID = await fetchSoleConversationObjectID(in: syncContext)
        let conversationID = try XCTUnwrap(fetchedConversationID)

        let manager = ConversationManager(currentUserEmail: { "me@example.com" })
        try await ConversationRollupMutationSerializer.shared.performThrowingSyncMutation(
            conversationIDs: [conversationID],
            in: syncContext
        ) {
            await manager.updateRollupsForModifiedConversations(
                conversationIDs: [conversationID],
                in: syncContext
            )
            try await syncContext.perform {
                try syncContext.save()
            }
        }
    }

    private func seedSystemLabels(in context: NSManagedObjectContext) throws {
        try context.performAndWait {
            LabelBuilder().inbox().build(in: context)
            LabelBuilder().unread().build(in: context)
            try context.save()
        }
    }

    private struct DurableConversationRow {
        let inboxUnreadCount: Int32
        let hasInbox: Bool
        let snippet: String?
        let lastMessageDate: Date?
        let latestInboxDate: Date?
    }

    /// Reads the sole conversation through a fresh context so only durable
    /// (saved) state counts — pending changes on the sync context are invisible.
    private func fetchDurableConversationRow() throws -> DurableConversationRow? {
        let verificationContext = stack.newBackgroundContext()
        return verificationContext.performAndWait {
            let request = Conversation.fetchRequest()
            request.fetchLimit = 1
            guard let conversation = try? verificationContext.fetch(request).first else {
                return nil
            }
            return DurableConversationRow(
                inboxUnreadCount: conversation.inboxUnreadCount,
                hasInbox: conversation.hasInbox,
                snippet: conversation.snippet,
                lastMessageDate: conversation.lastMessageDate,
                latestInboxDate: conversation.latestInboxDate
            )
        }
    }

    private func fetchSoleConversationObjectID(in context: NSManagedObjectContext) async -> NSManagedObjectID? {
        await context.perform {
            let request = Conversation.fetchRequest()
            request.fetchLimit = 1
            return try? context.fetch(request).first?.objectID
        }
    }
}
