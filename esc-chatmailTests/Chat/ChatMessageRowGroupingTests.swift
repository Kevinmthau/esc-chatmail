import XCTest
import CoreData
@testable import esc_chatmail

/// `ChatMessageRowGrouping.isFirstFromSender`, the mirror of `isLastFromSender` that the Mac's
/// transcript reads to start a run (`ChatTranscriptRunPolicy`).
///
/// Fixtures go through a main-queue context, as `ChatMessageRowModelTests` explains.
@MainActor
final class ChatMessageRowGroupingTests: XCTestCase {
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

    private func row(_ id: String, sender: String, fromMe: Bool = false) throws -> ChatMessageRowModel {
        var builder = MessageBuilder().withId(id).withSender(email: sender)
        if fromMe { builder = builder.fromMe() }
        let message = builder.build(in: viewContext)
        try viewContext.save()
        return ChatMessageRowModelMapper.map(message)
    }

    private func key(_ row: ChatMessageRowModel?) -> String? {
        row.map { $0.isFromMe ? "me" : "email:\($0.senderEmail ?? "")" }
    }

    /// Revert-check: returning false for a nil `previous` in `isFirstFromSender` makes this
    /// fail.
    func testIsFirstFromSender_conversationsFirstRow() throws {
        let first = try row("a", sender: "ada@example.com")
        XCTAssertTrue(ChatMessageRowGrouping.isFirstFromSender(current: first, previous: nil, senderRunKey: key))
    }

    /// Revert-check: deleting the run-key comparison from `isFirstFromSender` makes the
    /// different-sender assertion fail; returning true makes the same-sender one fail.
    func testIsFirstFromSender_followsTheSenderRunKey() throws {
        let ada1 = try row("a1", sender: "ada@example.com")
        let ada2 = try row("a2", sender: "ada@example.com")
        let grace = try row("g1", sender: "grace@example.com")

        XCTAssertFalse(ChatMessageRowGrouping.isFirstFromSender(current: ada2, previous: ada1, senderRunKey: key))
        XCTAssertTrue(ChatMessageRowGrouping.isFirstFromSender(current: grace, previous: ada2, senderRunKey: key))
    }

    /// A key that groups two rows does not join the user's row to someone else's.
    ///
    /// Revert-check: deleting the `isFromMe` comparison from `isFirstFromSender` makes this
    /// fail.
    func testIsFirstFromSender_directionChangeStartsARunWhateverTheKeySays() throws {
        let incoming = try row("i", sender: "ada@example.com")
        let outgoing = try row("o", sender: "ada@example.com", fromMe: true)

        XCTAssertTrue(ChatMessageRowGrouping.isFirstFromSender(
            current: outgoing,
            previous: incoming,
            senderRunKey: { _ in "same" }
        ))
    }
}
