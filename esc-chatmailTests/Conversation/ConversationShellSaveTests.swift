import XCTest
import CoreData
@testable import esc_chatmail

/// The creation serializer commits new conversation shells in a dedicated
/// sibling context. These tests pin the transaction boundary that replaces
/// the old caller-context save: the shell publishes immediately (dedup + UI
/// contracts), while the caller's half-processed batch state stays unsaved.
final class ConversationShellSaveTests: XCTestCase {
    private var testStack: TestCoreDataStack!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
    }

    override func tearDown() {
        testStack = nil
        super.tearDown()
    }

    private func makeIdentity(email: String = "alice@example.com") -> ConversationIdentity {
        makeConversationIdentity(
            from: [
                MessageHeader(name: "From", value: "Alice Smith <\(email)>"),
                MessageHeader(name: "To", value: "me@example.com")
            ],
            myAliases: ["me@example.com"]
        )
    }

    /// The core boundary: the shell save must not commit unrelated pending
    /// state in the caller's context (previously it saved the whole context,
    /// punching through the orchestrator's intermediate-save guard).
    func testShellSaveDoesNotCommitCallerContextState() async throws {
        let context = testStack.newBackgroundContext()

        // Unrelated pending state a mid-batch save would have committed.
        await context.perform {
            let person = context.insertTestObject(Person.self)
            person.id = UUID()
            person.email = "pending-bystander@example.com"
        }

        let serializer = ConversationCreationSerializer()
        let objectID = try await serializer.findOrCreateConversationObjectID(
            for: makeIdentity(),
            initialSnippet: "hello",
            in: context
        )
        XCTAssertFalse(objectID.isTemporaryID, "Callers rely on a permanent ID")

        // Fresh context, store truth only.
        let verification = testStack.newBackgroundContext()
        let (shellCount, bystanderCount): (Int, Int) = await verification.perform {
            let conversations = Conversation.fetchRequest()
            conversations.includesPendingChanges = false
            let persons = Person.fetchRequest()
            persons.predicate = NSPredicate(format: "email == %@", "pending-bystander@example.com")
            persons.includesPendingChanges = false
            return (
                (try? verification.count(for: conversations)) ?? -1,
                (try? verification.count(for: persons)) ?? -1
            )
        }
        XCTAssertEqual(shellCount, 1, "The shell must be store-visible immediately")
        XCTAssertEqual(bystanderCount, 0, "Caller-context pending state must NOT be committed")

        let callerStillDirty = await context.perform { context.hasChanges }
        XCTAssertTrue(callerStillDirty, "The caller's pending changes remain its own to save")
    }

    /// The published row must carry its full identity: participants (and
    /// their Person rows) are durable WITH the shell save. A durable
    /// participant-less conversation would match the maintenance sweep's
    /// empty-conversation predicate and render as "Unknown Contact".
    func testParticipantsAreDurableWithThePublishedShell() async throws {
        let context = testStack.newBackgroundContext()
        let serializer = ConversationCreationSerializer()

        _ = try await serializer.findOrCreateConversationObjectID(
            for: makeIdentity(),
            in: context
        )

        // Fresh context, store truth only, no caller save.
        let verification = testStack.newBackgroundContext()
        let (participantCount, personCount): (Int, Int) = await verification.perform {
            let participants = ConversationParticipant.fetchRequest()
            participants.includesPendingChanges = false
            let persons = Person.fetchRequest()
            persons.predicate = NSPredicate(format: "email == %@", "alice@example.com")
            persons.includesPendingChanges = false
            return (
                (try? verification.count(for: participants)) ?? -1,
                (try? verification.count(for: persons)) ?? -1
            )
        }
        XCTAssertEqual(participantCount, 1, "Participants must publish with the shell, not lag it")
        XCTAssertEqual(personCount, 1, "The participant's Person row must be durable too")
    }

    /// Intra-batch dedup: a second resolution for the same identity on the
    /// same caller context must find the shell in the store, not create a
    /// duplicate.
    func testSecondResolutionReusesTheShell() async throws {
        let context = testStack.newBackgroundContext()
        let serializer = ConversationCreationSerializer()

        let first = try await serializer.findOrCreateConversationObjectID(
            for: makeIdentity(),
            in: context
        )
        let second = try await serializer.findOrCreateConversationObjectID(
            for: makeIdentity(),
            in: context
        )

        XCTAssertEqual(first, second)
        let verification = testStack.newBackgroundContext()
        let count: Int = await verification.perform {
            let request = Conversation.fetchRequest()
            request.includesPendingChanges = false
            return (try? verification.count(for: request)) ?? -1
        }
        XCTAssertEqual(count, 1)
    }

    /// A failed dedup lookup must throw — creating anyway could duplicate a
    /// conversation that exists but could not be read. The store's request
    /// log proves the abort happened AT the lookup: the failing store saw
    /// only fetch requests, never a save.
    func testLookupFailureThrowsInsteadOfCreating() async throws {
        let failingContext = try FailingReadStore.makeFailingContext()
        let failingStore = try XCTUnwrap(
            failingContext.persistentStoreCoordinator?.persistentStores.first as? FailingReadStore
        )
        let serializer = ConversationCreationSerializer()

        do {
            _ = try await serializer.findOrCreateConversationObjectID(
                for: makeIdentity(),
                in: failingContext
            )
            XCTFail("A failed lookup must not silently proceed to creation")
        } catch {
            // Expected.
        }

        XCTAssertEqual(
            failingStore.requestTypes, [.fetchRequestType],
            "The serializer must abort at the dedup lookup, before any create/save reaches a store"
        )
    }
}
