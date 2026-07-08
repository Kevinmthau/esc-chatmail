import XCTest
import CoreData
@testable import esc_chatmail

final class ConversationCreationSerializerTests: XCTestCase {
    private var stack: TestCoreDataStack!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
    }

    override func tearDown() {
        stack = nil
        super.tearDown()
    }

    func testCreateSeedsSnippetAlongsideLastMessageDateInTheImmediateSave() async throws {
        // The serializer publishes the new conversation row before its first
        // message persists; a seeded date without a seeded snippet renders as
        // a timestamped "No messages" row for the whole gap.
        let identity = makeConversationIdentity(
            from: [
                MessageHeader(name: "From", value: "Daisy Wong <daisy@example.com>"),
                MessageHeader(name: "To", value: "me@example.com")
            ],
            gmThreadId: "thread-seed",
            myAliases: ["me@example.com"]
        )
        let messageDate = Date(timeIntervalSince1970: 1_700_000_000)
        let context = stack.newBackgroundContext()

        let objectID = try await ConversationCreationSerializer.shared.findOrCreateConversationObjectID(
            for: identity,
            initialLastMessageDate: messageDate,
            initialSnippet: "Attached a summary of the bedroom",
            in: context
        )

        // Read through a separate context so only the serializer's own save counts.
        let verificationContext = stack.newBackgroundContext()
        let row: (snippet: String?, lastMessageDate: Date?)? = await verificationContext.perform {
            guard let conversation = try? verificationContext.existingObject(with: objectID) as? Conversation else {
                return nil
            }
            return (conversation.snippet, conversation.lastMessageDate)
        }

        let persisted = try XCTUnwrap(row)
        XCTAssertEqual(persisted.snippet, "Attached a summary of the bedroom")
        XCTAssertEqual(persisted.lastMessageDate, messageDate)
    }

    func testCreateNormalizesWhitespaceOnlySeedToNil() async throws {
        let identity = makeConversationIdentity(
            from: [
                MessageHeader(name: "From", value: "blank@example.com"),
                MessageHeader(name: "To", value: "me@example.com")
            ],
            gmThreadId: "thread-blank-seed",
            myAliases: ["me@example.com"]
        )
        let context = stack.newBackgroundContext()

        let objectID = try await ConversationCreationSerializer.shared.findOrCreateConversationObjectID(
            for: identity,
            initialLastMessageDate: Date(timeIntervalSince1970: 1_700_000_100),
            initialSnippet: "  \n\t ",
            in: context
        )

        let snippet: String?? = await context.perform {
            (try? context.existingObject(with: objectID) as? Conversation)?.snippet
        }
        XCTAssertNil(snippet ?? nil)
    }
}
