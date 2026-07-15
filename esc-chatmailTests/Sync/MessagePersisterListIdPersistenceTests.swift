import XCTest
import CoreData
@testable import esc_chatmail

/// Pins the persistence of the normalized List-Id on Message rows. The strict
/// identity derivation and the future backfill both read `Message.listId`, so
/// ingest must store the normalized value and refetches must never clear it.
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

        let message = try XCTUnwrap(fetchDurableMessage())
        XCTAssertEqual(message.listId, "swift-evolution.swift.org")
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

        let message = try XCTUnwrap(fetchDurableMessage())
        XCTAssertNil(message.listId)
    }

    func testUpdatePersistsNormalizedListId() async throws {
        let syncContext = stack.newBackgroundContext()
        let persister = makePersister()

        try await persister.createNewMessage(
            makeArrival(listId: nil),
            labelIds: ["INBOX"],
            myAliases: ["me@example.com"],
            in: syncContext
        )
        try await syncContext.perform { try syncContext.save() }

        let didUpdate = await persister.updateExistingMessage(
            makeArrival(listId: "<list.example.com>"),
            labelIds: ["INBOX"],
            in: syncContext
        )
        XCTAssertTrue(didUpdate)
        try await syncContext.perform { try syncContext.save() }

        let message = try XCTUnwrap(fetchDurableMessage())
        XCTAssertEqual(message.listId, "list.example.com")
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

        let message = try XCTUnwrap(fetchDurableMessage())
        XCTAssertEqual(message.listId, "list.example.com")
    }

    // MARK: - Helpers

    private func makePersister() -> MessagePersister {
        MessagePersister(photoPrefetcher: { _ in })
    }

    private func makeArrival(id: String = "msg-list-id", listId: String?) -> ProcessedMessage {
        var headers = ProcessedHeaders()
        headers.subject = "List post"
        headers.from = "Sender <sender@example.com>"
        headers.to = [EmailAddress(email: "me@example.com", displayName: nil)]
        headers.isFromMe = false
        headers.listId = listId

        var processed = ProcessedMessage()
        processed.id = id
        processed.gmThreadId = "thread-list-id"
        processed.snippet = "List post body"
        processed.cleanedSnippet = "List post body"
        processed.chatPreviewText = "List post body"
        processed.internalDate = Date(timeIntervalSince1970: 1_700_000_000)
        processed.headers = headers
        processed.plainTextBody = "List post body"
        processed.labelIds = ["INBOX"]
        return processed
    }

    /// Reads the sole message through a fresh context so only durable (saved)
    /// state counts.
    private func fetchDurableMessage() throws -> Message? {
        let verificationContext = stack.newBackgroundContext()
        return verificationContext.performAndWait {
            let request = Message.fetchRequest()
            request.fetchLimit = 1
            return try? verificationContext.fetch(request).first
        }
    }
}
