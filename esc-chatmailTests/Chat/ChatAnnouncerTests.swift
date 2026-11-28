import CoreData
import XCTest
@testable import esc_chatmail

/// The open chat's announcer (architecture review 2026-11, gap-accessibility-architecture#2):
/// it speaks what the policy says, spaces arrival announcements, and posts through the closure
/// it is given, which here records.
@MainActor
final class ChatAnnouncerTests: XCTestCase {
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

    /// A burst of arrivals within the minimum spacing is announced once; one after it is
    /// announced again.
    ///
    /// Revert-check: dropping the `allowsArrivalAnnouncement` guard in
    /// `ChatAnnouncer.announceArrivals` speaks the second arrival too.
    func testAnnounceArrivals_withinTheSpacing_speaksOnce() {
        var spoken: [String] = []
        var now: TimeInterval = 1_000
        let announcer = ChatAnnouncer(post: { spoken.append($0) }, now: { now })
        let row = makeIncomingRow(sender: "Alice")

        announcer.announceArrivals([row])
        now += ChatTranscriptAnnouncementPolicy.minimumArrivalAnnouncementSpacing - 1
        announcer.announceArrivals([row])
        XCTAssertEqual(spoken, ["New message from Alice"])

        now += 1
        announcer.announceArrivals([row])
        XCTAssertEqual(spoken, ["New message from Alice", "New message from Alice"])
    }

    /// Rows that make no announcement (the user's own, or none) do not use up the spacing.
    ///
    /// Revert-check: stamping `lastArrivalAnnouncementAt` before the policy's nil check in
    /// `ChatAnnouncer.announceArrivals` silences the arrival after it.
    func testAnnounceArrivals_nothingToSay_leavesTheSpacingUnused() {
        var spoken: [String] = []
        let announcer = ChatAnnouncer(post: { spoken.append($0) }, now: { 1_000 })

        announcer.announceArrivals([])
        announcer.announceArrivals([makeIncomingRow(sender: "Bob")])

        XCTAssertEqual(spoken, ["New message from Bob"])
    }

    /// Send outcomes are spoken as the policy words them, unspaced.
    func testAnnounceSendOutcomes_speaksEachFailedReply() {
        var spoken: [String] = []
        let announcer = ChatAnnouncer(post: { spoken.append($0) }, now: { 1_000 })
        let reply = ChatMessageDisplayIdentity.outboundSend(optimisticMessageID: "reply-\(UUID().uuidString)")

        announcer.announceSendOutcomes(old: [reply: .sending], new: [reply: .sendFailed])

        XCTAssertEqual(spoken, ["Your message failed to send"])
    }

    private func makeIncomingRow(sender: String) -> ChatMessageRowModel {
        ChatMessageRowModelMapper.map(
            MessageBuilder()
                .withId("announcer-\(UUID().uuidString)")
                .withSender(email: "\(sender.lowercased())@example.com", name: sender)
                .build(in: viewContext)
        )
    }
}
