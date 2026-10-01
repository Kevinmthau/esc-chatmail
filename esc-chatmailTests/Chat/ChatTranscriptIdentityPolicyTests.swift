import XCTest
import CoreData
@testable import esc_chatmail

/// Every fixture, save, and assertion goes through the suite's `viewContext`, a
/// main-queue context from `TestCoreDataStack.makeMainQueueViewContext()`,
/// never `stack.viewContext`, which is private-queue:
/// `ChatMessageRowModelMapper.map` is `@MainActor` and fetches on each
/// message's own context.
@MainActor
final class ChatTranscriptIdentityPolicyTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var viewContext: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        viewContext = stack.makeMainQueueViewContext()
    }

    override func tearDown() {
        viewContext = nil
        stack = nil
        super.tearDown()
    }

    /// While sync defers consuming an optimistic row whose echo it already
    /// created, both render and both map to the same `.outboundSend` identity.
    /// The `ForEach` must still see unique IDs, and the echo — the row that
    /// survives — keeps the shared identity so the view that showed the
    /// optimistic bubble becomes the echo's.
    ///
    /// Revert-check: returning each row's raw `displayIdentity` from
    /// `ChatTranscriptIdentityPolicy.rows(for:)` (dropping the de-duplication)
    /// fails the uniqueness and fallback assertions.
    func testRows_optimisticAndEchoCoexist_neverShareIdentityAndEchoKeepsIt() throws {
        let optimisticID = UUID().uuidString
        let rfcMessageID = MimeBuilder.messageId(forOptimisticMessageID: optimisticID)
        let earlier = MessageBuilder()
            .withId("earlier-id")
            .withDate(Date(timeIntervalSince1970: 1))
            .build(in: viewContext)
        let optimistic = MessageBuilder()
            .withId(optimisticID)
            .withDate(Date(timeIntervalSince1970: 2))
            .fromMe()
            .build(in: viewContext)
        optimistic.messageId = rfcMessageID
        let echo = MessageBuilder()
            .withId("gmail-echo-id")
            .withDate(Date(timeIntervalSince1970: 3))
            .fromMe()
            .build(in: viewContext)
        echo.messageId = rfcMessageID
        try viewContext.save()

        let messages = ChatMessageRowModelMapper.map([earlier, optimistic, echo])
        XCTAssertTrue(messages[1].isAwaitingSyncEcho)
        XCTAssertFalse(messages[2].isAwaitingSyncEcho)

        let rows = ChatTranscriptIdentityPolicy.rows(for: messages)

        XCTAssertEqual(rows.map(\.index), [0, 1, 2])
        XCTAssertEqual(rows.map(\.message.objectID), messages.map(\.objectID))
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        XCTAssertEqual(rows[0].id, .message(earlier.objectID))
        XCTAssertEqual(rows[1].id, .message(optimistic.objectID))
        XCTAssertEqual(rows[2].id, .outboundSend(optimisticMessageID: optimisticID))
    }

    /// Without a collision every row keeps its own display identity, so an
    /// optimistic reply's view carries over to its echo once the optimistic
    /// row is gone.
    func testRows_noSharedIdentity_keepsEachRowsDisplayIdentity() throws {
        let optimisticID = UUID().uuidString
        let incoming = MessageBuilder()
            .withId("incoming-id")
            .withDate(Date(timeIntervalSince1970: 1))
            .build(in: viewContext)
        let echo = MessageBuilder()
            .withId("gmail-echo-id")
            .withDate(Date(timeIntervalSince1970: 2))
            .fromMe()
            .build(in: viewContext)
        echo.messageId = MimeBuilder.messageId(forOptimisticMessageID: optimisticID)
        try viewContext.save()

        let messages = ChatMessageRowModelMapper.map([incoming, echo])
        let rows = ChatTranscriptIdentityPolicy.rows(for: messages)

        XCTAssertEqual(rows.map(\.id), messages.map(\.displayIdentity))
        XCTAssertEqual(rows[1].id, .outboundSend(optimisticMessageID: optimisticID))
    }
}
