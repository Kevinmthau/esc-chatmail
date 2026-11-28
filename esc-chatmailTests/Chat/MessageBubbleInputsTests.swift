import XCTest
import CoreData
@testable import esc_chatmail

/// What makes two transcript rows' bubbles equal, which is what lets the transcript skip a
/// row's body (`MessageBubble`'s `==`, shown through `.equatable()`; architecture review
/// 2026-11, chat-transcript-ui#4).
///
/// The fixtures live on this suite's main-queue context, never `stack.viewContext`, which is
/// private-queue: the mapper reads the message on the calling thread.
@MainActor
final class MessageBubbleInputsTests: XCTestCase {
    private var stack: TestCoreDataStack!
    private var viewContext: NSManagedObjectContext!
    private var htmlContentHandler: HTMLContentHandler!

    override func setUp() {
        super.setUp()
        stack = TestCoreDataStack()
        viewContext = stack.makeMainQueueViewContext()
        let messagesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MessageBubbleInputsTests-\(UUID().uuidString)", isDirectory: true)
        htmlContentHandler = HTMLContentHandler(messagesDirectory: messagesDirectory)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: messagesDirectory)
        }
    }

    override func tearDown() {
        htmlContentHandler = nil
        viewContext = nil
        stack = nil
        super.tearDown()
    }

    /// Two passes of the transcript build two bubbles for one row with new closures each time.
    /// With nothing else different they are equal, so the second pass skips the row's body.
    ///
    /// HONEST SCOPE: Swift cannot compare closures, so no plausible edit makes `MessageBubble.==`
    /// read them, and a synthesized `==` does not compile. This fails for an `==` stricter than
    /// the inputs (checked with `lhs.inputs == rhs.inputs && false`).
    func testBubbles_differingOnlyInTheirClosures_areEqual() {
        let row = makeRow()
        var firstPassCalls = 0
        var secondPassCalls = 0

        let first = makeBubble(row: row, onSendRecoveryAction: { _ in firstPassCalls += 1 })
        let second = makeBubble(row: row, onSendRecoveryAction: { _ in secondPassCalls += 1 })

        XCTAssertTrue(first == second)
        XCTAssertEqual(firstPassCalls + secondPassCalls, 0)
    }

    /// The receipt moving to a newer row redraws both rows.
    ///
    /// Revert-check: `MessageBubble.==` comparing `inputs.message` alone (an input kept beside
    /// the struct, not in it) makes the two equal.
    func testBubbles_differingInWhetherNewest_areNotEqual() {
        let row = makeRow()

        XCTAssertFalse(makeBubble(row: row, isNewestInTranscript: true) == makeBubble(row: row, isNewestInTranscript: false))
    }

    /// A contacts change redraws every row, which reloads its sender.
    ///
    /// Revert-check: `MessageBubble.==` comparing `inputs.message` alone makes the two equal.
    func testBubbles_differingInContactRefreshToken_areNotEqual() {
        let row = makeRow()

        XCTAssertFalse(makeBubble(row: row, contactRefreshToken: 1) == makeBubble(row: row, contactRefreshToken: 2))
    }

    /// A verdict stamped while the row is mounted redraws it (the row model differs) without
    /// restarting its load (its load signature does not).
    ///
    /// Revert-check: `MessageBubble.==` comparing the row's `loadSignatureComponents` and ID in
    /// place of the whole row makes the two equal.
    func testBubbles_differingOnlyInTheStoredVerdict_areNotEqualAndKeepTheirLoadSignature() {
        let message = MessageBuilder()
            .withId("inputs-verdict-\(UUID().uuidString)")
            .build(in: viewContext)
        message.chatPreviewText = "Stored preview"
        message.storedRichContentVerdict = .notRich
        let notRich = ChatMessageRowModelMapper.map(message)
        message.storedRichContentVerdict = .rich
        let rich = ChatMessageRowModelMapper.map(message)

        XCTAssertFalse(makeBubble(row: notRich) == makeBubble(row: rich))
        XCTAssertEqual(notRich.loadSignatureComponents, rich.loadSignatureComponents)
    }

    /// Each of the other inputs redraws the row it changes.
    ///
    /// Revert-check: `MessageBubble.==` comparing `inputs.message` alone makes every assertion
    /// but the last fail.
    func testBubbles_differingInAnyOtherInput_areNotEqual() {
        let row = makeRow()
        let base = makeBubble(row: row)

        XCTAssertFalse(base == makeBubble(row: row, prefetchedSenderName: "Someone"))
        XCTAssertFalse(base == makeBubble(row: row, isEffectivelyOneToOneConversation: false))
        XCTAssertFalse(base == makeBubble(row: row, runPlacement: ChatTranscriptRunPlacement(
            startsRun: false,
            endsRun: false,
            separatorDate: nil,
            topPadding: 0
        )))
        XCTAssertFalse(base == makeBubble(row: row, transcriptWidth: 500))
        XCTAssertFalse(base == makeBubble(row: row, style: .mac))
        XCTAssertFalse(base == makeBubble(row: makeRow()))
    }

    // MARK: - Helpers

    private func makeRow() -> ChatMessageRowModel {
        let message = MessageBuilder()
            .withId("inputs-\(UUID().uuidString)")
            .withBody("Hello")
            .build(in: viewContext)
        return ChatMessageRowModelMapper.map(message)
    }

    private func makeBubble(
        row: ChatMessageRowModel,
        prefetchedSenderName: String? = nil,
        isEffectivelyOneToOneConversation: Bool = true,
        contactRefreshToken: Int = 0,
        runPlacement: ChatTranscriptRunPlacement = .alone,
        transcriptWidth: CGFloat = 390,
        isNewestInTranscript: Bool = false,
        style: MessageBubbleStyle = .standard,
        onSendRecoveryAction: @escaping (FailedSendRecoveryPolicy.Action) -> Void = { _ in }
    ) -> MessageBubble {
        MessageBubble(
            message: row,
            messageBubbleLoader: MockMessageBubbleLoader(senderResults: [], contentResults: []),
            htmlContentHandler: htmlContentHandler,
            fullEmailOpener: FullEmailWebViewManager.shared,
            originalEmailSourceWarmer: OriginalEmailSourceLoader.shared,
            prefetchedSenderName: prefetchedSenderName,
            isEffectivelyOneToOneConversation: isEffectivelyOneToOneConversation,
            contactRefreshToken: contactRefreshToken,
            runPlacement: runPlacement,
            transcriptWidth: transcriptWidth,
            isNewestInTranscript: isNewestInTranscript,
            style: style,
            onOpenFullMessage: { _, _ in },
            onSendRecoveryAction: onSendRecoveryAction
        )
    }
}
