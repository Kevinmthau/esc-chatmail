import CoreData
import XCTest
@testable import esc_chatmail

/// What the open chat announces (architecture review 2026-11,
/// gap-accessibility-architecture#2). In the default plan and in `Mac.xctestplan`. Rows come
/// from an in-memory store on this suite's main-queue context, as the mapper reads them.
///
/// HONEST SCOPE: the policy only. That the coordinator announces the IDs it marked, and only
/// while uncovered, is `ChatMessagesCoordinatorTests`'; the spacing is `ChatAnnouncerTests`'.
/// No announcement has been heard with VoiceOver on either platform.
@MainActor
final class ChatTranscriptAnnouncementPolicyTests: XCTestCase {
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

    // MARK: - Send outcomes

    /// A reply leaving `.sending` for each failed or uncertain state is announced once.
    ///
    /// Revert-check: announcing whatever the old status (dropping `old[identity] == .sending`
    /// in `ChatTranscriptAnnouncementPolicy.sendOutcomeAnnouncements`) fails the next test,
    /// and returning nothing for `.deliveryUnknown` in `sendOutcomeText` fails this one.
    func testSendOutcome_sendingToEachFailedState_announcesOnce() {
        let a = Self.reply("a")
        let b = Self.reply("b")
        let c = Self.reply("c")

        let announcements = ChatTranscriptAnnouncementPolicy.sendOutcomeAnnouncements(
            old: [a: .sending, b: .sending, c: .sending],
            new: [a: .notSent, b: .deliveryUnknown, c: .sendFailed]
        )

        XCTAssertEqual(announcements.count, 3)
        XCTAssertEqual(Set(announcements), [
            "Your message was not sent",
            "Delivery of your message is unknown",
            "Your message failed to send"
        ])
    }

    /// A row that arrives already failed (a window load, a chat opened on a failed reply), a
    /// row that was already failed, and the echo replacing a sent reply announce nothing.
    ///
    /// Revert-check: dropping `old[identity] == .sending` in
    /// `ChatTranscriptAnnouncementPolicy.sendOutcomeAnnouncements` announces the first two.
    func testSendOutcome_noTransitionOutOfSending_announcesNothing() {
        let reply = Self.reply("a")

        XCTAssertEqual(ChatTranscriptAnnouncementPolicy.sendOutcomeAnnouncements(old: [:], new: [reply: .notSent]), [])
        XCTAssertEqual(ChatTranscriptAnnouncementPolicy.sendOutcomeAnnouncements(old: [reply: .notSent], new: [reply: .notSent]), [])
        XCTAssertEqual(ChatTranscriptAnnouncementPolicy.sendOutcomeAnnouncements(old: [reply: .sending], new: [:]), [])
    }

    /// Only the user's own rows with a status are keyed: someone else's row and an own row
    /// with no status are left out.
    ///
    /// Revert-check: keeping rows whose status is `.none` (dropping `if status != .none` in
    /// `ChatTranscriptAnnouncementPolicy.ownSendStatuses`) fails this.
    ///
    /// HONEST SCOPE: an incoming row's status is always `.none`, so no fixture tells the
    /// `where row.isFromMe` filter from the `.none` one; it is there for a row the mapper
    /// someday gives one.
    func testOwnSendStatuses_leaveOutOthersRowsAndRowsWithNoStatus() {
        let incoming = makeRow(id: "incoming", fromMe: false)
        let sentAndDone = makeRow(id: "sent", fromMe: true)

        XCTAssertEqual(ChatTranscriptAnnouncementPolicy.ownSendStatuses(rows: [incoming, sentAndDone]), [:])
    }

    // MARK: - Arrivals

    /// One arrival names its sender; several from one sender count them; several from more
    /// than one say how many. No content is said.
    ///
    /// Revert-check: "New message" for a named single arrival in
    /// `ChatTranscriptAnnouncementPolicy.arrivalAnnouncement` fails the first assertion.
    func testArrivalAnnouncement_namesTheSenderOrCountsTheMessages() {
        let alice1 = makeRow(id: "alice-1", fromMe: false, senderName: "Alice", body: "the secret plan")
        let alice2 = makeRow(id: "alice-2", fromMe: false, senderName: "Alice")
        let bob = makeRow(id: "bob", fromMe: false, senderName: "Bob")

        XCTAssertEqual(ChatTranscriptAnnouncementPolicy.arrivalAnnouncement(rows: [alice1]), "New message from Alice")
        XCTAssertEqual(ChatTranscriptAnnouncementPolicy.arrivalAnnouncement(rows: [alice1, alice2]), "2 new messages from Alice")
        XCTAssertEqual(ChatTranscriptAnnouncementPolicy.arrivalAnnouncement(rows: [alice1, bob]), "2 new messages")
        XCTAssertFalse(ChatTranscriptAnnouncementPolicy.arrivalAnnouncement(rows: [alice1])?.contains("secret") ?? true)
    }

    /// The user's own rows are never an arrival.
    ///
    /// Revert-check: dropping the `!$0.isFromMe` filter in
    /// `ChatTranscriptAnnouncementPolicy.arrivalAnnouncement` fails this.
    func testArrivalAnnouncement_ownRowsOnly_isNil() {
        XCTAssertNil(ChatTranscriptAnnouncementPolicy.arrivalAnnouncement(rows: [makeRow(id: "mine", fromMe: true)]))
        XCTAssertNil(ChatTranscriptAnnouncementPolicy.arrivalAnnouncement(rows: []))
    }

    /// Arrival announcements are spaced at least the minimum apart.
    ///
    /// Revert-check: `true` from `ChatTranscriptAnnouncementPolicy.allowsArrivalAnnouncement`
    /// whatever the times fails the second assertion.
    func testAllowsArrivalAnnouncement_onlyAfterTheMinimumSpacing() {
        let spacing = ChatTranscriptAnnouncementPolicy.minimumArrivalAnnouncementSpacing

        XCTAssertTrue(ChatTranscriptAnnouncementPolicy.allowsArrivalAnnouncement(at: 100, lastAnnouncedAt: nil))
        XCTAssertFalse(ChatTranscriptAnnouncementPolicy.allowsArrivalAnnouncement(at: 100 + spacing - 0.1, lastAnnouncedAt: 100))
        XCTAssertTrue(ChatTranscriptAnnouncementPolicy.allowsArrivalAnnouncement(at: 100 + spacing, lastAnnouncedAt: 100))
    }

    // MARK: - Helpers

    private static func reply(_ suffix: String) -> ChatMessageDisplayIdentity {
        .outboundSend(optimisticMessageID: "announce-\(suffix)-\(UUID().uuidString)")
    }

    private func makeRow(
        id: String,
        fromMe: Bool,
        senderName: String = "Someone",
        body: String = "Hello"
    ) -> ChatMessageRowModel {
        var builder = MessageBuilder()
            .withId("\(id)-\(UUID().uuidString)")
            .withSender(email: "\(senderName.lowercased())@example.com", name: senderName)
            .withBody(body)
        if fromMe {
            builder = builder.fromMe()
        }
        return ChatMessageRowModelMapper.map(builder.build(in: viewContext))
    }
}
