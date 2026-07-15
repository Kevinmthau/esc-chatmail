import XCTest
import CoreData
@testable import esc_chatmail

/// End-to-end router coverage for List-Id grouping: messages carrying a
/// parseable List-Id header key their conversation by the "l|" list hash, so
/// one mailing list stays one chat as senders and recipients vary.
final class MessageConversationRouterListTests: XCTestCase {
    private var stack: TestCoreDataStack!

    private static let listIdRaw = "Swift Weekly <swift-weekly.example.com>"
    private static let listIdNormalized = "swift-weekly.example.com"
    private static let listHash = calculateListConversationHash(fromNormalizedListId: listIdNormalized)

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
    }

    override func tearDown() {
        stack = nil
        super.tearDown()
    }

    func testSameListIdAcrossDifferentSendersGroupsIntoOneListConversation() async throws {
        let syncContext = stack.newBackgroundContext()
        try seedSystemLabels(in: syncContext)
        let persister = makePersister()

        try await persister.createNewMessage(
            makeListArrival(id: "msg-issue-1", from: "Editor A <a@swiftweekly.com>", date: 100),
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await persister.createNewMessage(
            makeListArrival(
                id: "msg-issue-2",
                from: "Editor B <b@other-relay.net>",
                to: "everyone@swift-weekly.example.com",
                date: 200
            ),
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform { try syncContext.save() }

        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 1, "Varying senders/recipients must not shatter one list")
        let list = try XCTUnwrap(states.first)
        XCTAssertEqual(list.typeRaw, ConversationType.list.rawValue)
        XCTAssertEqual(list.participantHash, Self.listHash)
        XCTAssertEqual(list.listId, Self.listIdNormalized)
        XCTAssertEqual(list.messageIDs, ["msg-issue-1", "msg-issue-2"])
    }

    func testMessageWithoutListIdStaysParticipantKeyed() async throws {
        let syncContext = stack.newBackgroundContext()
        try seedSystemLabels(in: syncContext)
        let persister = makePersister()

        try await persister.createNewMessage(
            makeListArrival(id: "msg-list", from: "Editor A <a@swiftweekly.com>", date: 100),
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        var plain = makeListArrival(id: "msg-plain", from: "Editor A <a@swiftweekly.com>", date: 200)
        plain.headers.listId = nil
        try await persister.createNewMessage(
            plain,
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform { try syncContext.save() }

        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 2, "Header-less mail from the same sender keeps participant keying")
        let plainState = try XCTUnwrap(states.first { $0.listId == nil })
        XCTAssertEqual(plainState.participantHash, calculateParticipantHash(from: ["a@swiftweekly.com"]))
        XCTAssertEqual(plainState.messageIDs, ["msg-plain"])
    }

    func testListTitleSeededFromPhraseOnDurableShellRow() async throws {
        let syncContext = stack.newBackgroundContext()
        try seedSystemLabels(in: syncContext)
        let persister = makePersister()

        try await persister.createNewMessage(
            makeListArrival(id: "msg-issue-1", from: "Editor A <a@swiftweekly.com>", date: 100),
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )

        // The sync context is deliberately NOT saved: the serializer's shell
        // save is the row the chat list publishes first, and it must already
        // carry the phrase title.
        let states = try fetchConversationStates()
        XCTAssertEqual(states.first?.displayName, "Swift Weekly")
    }

    func testArchivedListConversationReactivatesOnInboxArrival() async throws {
        let syncContext = stack.newBackgroundContext()
        try seedSystemLabels(in: syncContext)
        let persister = makePersister()

        try await persister.createNewMessage(
            makeListArrival(id: "msg-issue-1", from: "Editor A <a@swiftweekly.com>", date: 100),
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform { try syncContext.save() }
        try await archiveSoleConversation(in: syncContext)

        try await persister.createNewMessage(
            makeListArrival(id: "msg-issue-2", from: "Editor B <b@other-relay.net>", date: 200),
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform { try syncContext.save() }

        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 1, "An INBOX arrival must reuse and reactivate the archived list chat")
        let list = try XCTUnwrap(states.first)
        XCTAssertNil(list.archivedAt)
        XCTAssertEqual(list.messageIDs, ["msg-issue-1", "msg-issue-2"])
    }

    func testArchivedListConversationGetsNewEpochOnNonInboxArrival() async throws {
        let syncContext = stack.newBackgroundContext()
        try seedSystemLabels(in: syncContext)
        let persister = makePersister()

        try await persister.createNewMessage(
            makeListArrival(id: "msg-issue-1", from: "Editor A <a@swiftweekly.com>", date: 100),
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform { try syncContext.save() }
        try await archiveSoleConversation(in: syncContext)

        // A filtered/auto-archived arrival (no INBOX, not from me) must mint a
        // fresh epoch instead of resurrecting the archived chat.
        var filtered = makeListArrival(id: "msg-issue-2", from: "Editor B <b@other-relay.net>", date: 200)
        filtered.labelIds = []
        try await persister.createNewMessage(
            filtered,
            labelIds: [],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform { try syncContext.save() }

        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(Set(states.map(\.participantHash)), [Self.listHash], "Both epochs share the list hash")
        XCTAssertEqual(Set(states.map(\.keyHash)).count, 2, "Each epoch mints its own keyHash")
        let archived = try XCTUnwrap(states.first { $0.archivedAt != nil })
        XCTAssertEqual(archived.messageIDs, ["msg-issue-1"])
        let active = try XCTUnwrap(states.first { $0.archivedAt == nil })
        XCTAssertEqual(active.messageIDs, ["msg-issue-2"])
    }

    func testSelfAliasFromWithListIdGroupsIntoListConversation() async throws {
        let syncContext = stack.newBackgroundContext()
        try seedSystemLabels(in: syncContext)
        let persister = makePersister()

        // The list echoing back the user's own post still keys by List-Id —
        // not by the self-conversation fallback.
        var echo = makeListArrival(id: "msg-own-post", from: "Me <me@example.com>", date: 100)
        echo.headers.isFromMe = true
        try await persister.createNewMessage(
            echo,
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform { try syncContext.save() }

        let states = try fetchConversationStates()
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.first?.participantHash, Self.listHash)
        XCTAssertEqual(states.first?.typeRaw, ConversationType.list.rawValue)
    }

    // MARK: - Helpers

    private func makePersister() -> MessagePersister {
        MessagePersister(photoPrefetcher: { _ in })
    }

    private func makeListArrival(
        id: String,
        from: String,
        to: String = "me@example.com",
        date: TimeInterval
    ) -> ProcessedMessage {
        var headers = ProcessedHeaders()
        headers.subject = "Issue"
        headers.from = from
        headers.to = [EmailAddress(email: to, displayName: nil)]
        headers.isFromMe = false
        headers.listId = Self.listIdRaw

        var processed = ProcessedMessage()
        processed.id = id
        processed.gmThreadId = "thread-\(id)"
        processed.snippet = "Issue body"
        processed.cleanedSnippet = "Issue body"
        processed.chatPreviewText = "Issue body"
        processed.internalDate = Date(timeIntervalSince1970: date)
        processed.headers = headers
        processed.plainTextBody = "Issue body"
        processed.labelIds = ["INBOX"]
        return processed
    }

    private func archiveSoleConversation(in context: NSManagedObjectContext) async throws {
        try await context.perform {
            let request = Conversation.fetchRequest()
            request.fetchLimit = 1
            let conversation = try XCTUnwrap(try context.fetch(request).first)
            conversation.archivedAt = Date()
            try context.save()
        }
    }

    private func seedSystemLabels(in context: NSManagedObjectContext) throws {
        try context.performAndWait {
            LabelBuilder().inbox().build(in: context)
            LabelBuilder().unread().build(in: context)
            try context.save()
        }
    }

    private struct ConversationState {
        let id: UUID
        let keyHash: String
        let participantHash: String?
        let listId: String?
        let typeRaw: String
        let displayName: String?
        let archivedAt: Date?
        let messageIDs: Set<String>
    }

    /// Snapshots every conversation from a fresh context so assertions observe
    /// persisted store state only.
    private func fetchConversationStates() throws -> [ConversationState] {
        let fetchContext = stack.newBackgroundContext()
        return try fetchContext.performAndWait {
            let request = Conversation.fetchRequest()
            request.relationshipKeyPathsForPrefetching = ["messages"]
            return try fetchContext.fetch(request).map { conversation in
                ConversationState(
                    id: conversation.id,
                    keyHash: conversation.keyHash,
                    participantHash: conversation.participantHash,
                    listId: conversation.listId,
                    typeRaw: conversation.type,
                    displayName: conversation.displayName,
                    archivedAt: conversation.archivedAt,
                    messageIDs: Set((conversation.messages ?? []).map(\.id))
                )
            }
        }
    }
}
