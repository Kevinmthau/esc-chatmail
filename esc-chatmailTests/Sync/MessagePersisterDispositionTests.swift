import XCTest
import CoreData
@testable import esc_chatmail

/// Pins the per-ID persistence dispositions that gate cursor advancement:
/// every saved message lands in exactly one report bucket, and the failure
/// modes that used to be silent (routing failure, failed excluded-row delete,
/// failed existing-message lookup) surface as `.failed` / `.lookupFailed`.
final class MessagePersisterDispositionTests: XCTestCase {
    private var testStack: TestCoreDataStack!
    private var coreDataStack: CoreDataStack!

    private static let myEmail = "me@example.com"

    override func setUp() async throws {
        try await super.setUp()
        testStack = TestCoreDataStack()
        coreDataStack = CoreDataStack(persistentContainerForTesting: testStack.persistentContainer)
        await ModificationTracker.shared.reset()
    }

    override func tearDown() async throws {
        await ModificationTracker.shared.reset()
        coreDataStack = nil
        testStack = nil
        try await super.tearDown()
    }

    @MainActor
    private func makePersister(
        conversationCreationError: Error? = nil,
        coreDataStack: CoreDataStack? = nil
    ) -> MessagePersister {
        let conversationManager: ConversationManager
        if let conversationCreationError {
            conversationManager = ConversationManager(
                findOrCreateConversationHandler: { _, _, _, _, _, _ in
                    throw conversationCreationError
                },
                currentUserEmail: { Self.myEmail }
            )
        } else {
            conversationManager = ConversationManager(currentUserEmail: { Self.myEmail })
        }
        return MessagePersister(
            coreDataStack: coreDataStack ?? self.coreDataStack,
            saveHTML: { _, _ in nil },
            conversationManager: conversationManager
        )
    }

    private func makeFullMessage(id: String, labels: [String] = ["INBOX"]) -> GmailMessage {
        GmailMessageBuilder()
            .withId(id)
            .withThreadId("t-\(id)")
            .withLabels(labels)
            .withFrom("alice@example.com", name: "Alice Smith")
            .withTo([Self.myEmail])
            .withSubject("Subject \(id)")
            .withSnippet("Snippet \(id)")
            .build()
    }

    @MainActor
    func testSuccessfulCreateReportsPersisted() async throws {
        let persister = makePersister()
        let context = coreDataStack.newBackgroundContext()

        let report = try await persister.saveMessages(
            [makeFullMessage(id: "m-ok")],
            myAliases: [Self.myEmail],
            in: context
        )

        XCTAssertEqual(report.persistedIds, ["m-ok"])
        XCTAssertTrue(report.failedIds.isEmpty)
        XCTAssertTrue(report.excludedIds.isEmpty)
        XCTAssertTrue(report.unprocessableIds.isEmpty)
    }

    @MainActor
    func testExcludedMailboxMessageReportsExcludedAndRemovesLocalRow() async throws {
        let persister = makePersister()
        let context = coreDataStack.newBackgroundContext()

        // Seed a local row that the SPAM-labeled arrival must remove.
        _ = try await persister.saveMessages(
            [makeFullMessage(id: "m-spam")],
            myAliases: [Self.myEmail],
            in: context
        )
        try await coreDataStack.saveAsync(context: context)

        let report = try await persister.saveMessages(
            [makeFullMessage(id: "m-spam", labels: ["SPAM"])],
            myAliases: [Self.myEmail],
            in: context
        )
        try await coreDataStack.saveAsync(context: context)

        XCTAssertEqual(report.excludedIds, ["m-spam"])
        XCTAssertTrue(report.failedIds.isEmpty)

        let remaining: Int = await context.perform {
            let request = Message.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", "m-spam")
            request.includesPendingChanges = false
            return (try? context.count(for: request)) ?? -1
        }
        XCTAssertEqual(remaining, 0, "The excluded message's local row must be gone")
    }

    @MainActor
    func testUnprocessablePayloadReportsUnprocessable() async throws {
        let persister = makePersister()
        let context = coreDataStack.newBackgroundContext()

        // No payload/headers: MessageProcessor deterministically returns nil.
        let raw = GmailMessage(
            id: "m-raw",
            threadId: "t-raw",
            labelIds: ["INBOX"],
            snippet: nil,
            historyId: nil,
            internalDate: nil,
            payload: nil,
            sizeEstimate: nil
        )
        let report = try await persister.saveMessages([raw], myAliases: [Self.myEmail], in: context)

        XCTAssertEqual(report.unprocessableIds, ["m-raw"])
        XCTAssertTrue(report.failedIds.isEmpty)
        XCTAssertTrue(report.persistedIds.isEmpty)
    }

    @MainActor
    func testConversationRoutingFailureReportsFailed() async throws {
        struct RoutingFailure: Error {}
        let persister = makePersister(conversationCreationError: RoutingFailure())
        let context = coreDataStack.newBackgroundContext()

        let report = try await persister.saveMessages(
            [makeFullMessage(id: "m-doomed")],
            myAliases: [Self.myEmail],
            in: context
        )

        XCTAssertEqual(report.failedIds, ["m-doomed"], "A routing failure is a blocking per-message failure")
        XCTAssertTrue(report.persistedIds.isEmpty)
    }

    /// A failed existing-message lookup must be `.lookupFailed` — creating
    /// anyway could insert a duplicate of a row that exists but could not be
    /// read.
    @MainActor
    func testFailedLookupReportsLookupFailedNotNotPresent() async throws {
        let persister = makePersister()
        let failingContext = try FailingReadStore.makeFailingContext()

        let processed = await persister.prepareMessage(
            makeFullMessage(id: "m-unreadable"),
            myAliases: [Self.myEmail]
        )
        guard case .processed(let processedMessage) = processed else {
            return XCTFail("Fixture must prepare successfully")
        }

        let outcome = await persister.updateExistingMessageOutcome(
            processedMessage,
            labelIds: nil,
            myAliases: [Self.myEmail],
            modificationTransaction: nil,
            reroutedSourceRollupBuffer: nil,
            remoteCommittedSendMutation: nil,
            in: failingContext
        )

        XCTAssertEqual(outcome, .lookupFailed)
    }

    /// The full pipeline mapping: a failed lookup surfaces as `.failed` in
    /// the report (not persisted, not silently created).
    @MainActor
    func testFailedLookupSurfacesAsFailedInReport() async throws {
        let persister = makePersister()
        let failingContext = try FailingReadStore.makeFailingContext()

        let report = try await persister.saveMessages(
            [makeFullMessage(id: "m-unreadable")],
            myAliases: [Self.myEmail],
            in: failingContext
        )

        XCTAssertEqual(report.failedIds, ["m-unreadable"])
        XCTAssertTrue(report.persistedIds.isEmpty)
    }
}
