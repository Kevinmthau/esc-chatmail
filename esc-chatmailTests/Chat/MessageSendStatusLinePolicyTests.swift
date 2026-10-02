import XCTest
@testable import esc_chatmail

final class MessageSendStatusLinePolicyTests: XCTestCase {
    private typealias Policy = MessageSendStatusLinePolicy

    private func line(
        _ presentation: MessageSendStatusPresentation,
        isSendingRevealDue: Bool = false,
        isFromMe: Bool = true,
        isConfirmedInGmail: Bool = true,
        isNewestInTranscript: Bool = true
    ) -> Policy.Line? {
        Policy.line(
            presentation: presentation,
            isSendingRevealDue: isSendingRevealDue,
            isFromMe: isFromMe,
            isConfirmedInGmail: isConfirmedInGmail,
            isNewestInTranscript: isNewestInTranscript
        )
    }

    // MARK: - Sending grace period

    /// A send Gmail accepts within the grace period goes straight to "Sent" without "Sending…"
    /// flashing on and off.
    ///
    /// Revert-check: ignoring `isSendingRevealDue` in `MessageSendStatusLinePolicy.line` (always
    /// `.sending` while pending, as the old in-bubble indicator was) fails this test.
    func testLine_pendingInsideGracePeriod_showsNothing() {
        XCTAssertNil(line(.sending, isSendingRevealDue: false))
        XCTAssertNil(line(.sending, isSendingRevealDue: false, isNewestInTranscript: false))
    }

    func testLine_pendingPastGracePeriod_showsSendingOnAnyRow() {
        XCTAssertEqual(line(.sending, isSendingRevealDue: true), .sending)
        XCTAssertEqual(
            line(.sending, isSendingRevealDue: true, isNewestInTranscript: false),
            .sending
        )
        XCTAssertEqual(Policy.Line.sending.label, "Sending…")
    }

    /// Revert-check: replacing the elapsed-time subtraction in
    /// `MessageSendStatusLinePolicy.remainingSendingRevealDelay` with the full constant (timing
    /// from when the view appeared) fails the mid-send and long-pending assertions.
    ///
    /// HONEST SCOPE: pins the arithmetic. That `MessageBubble`'s `.task(id:)` sleeps for it and is
    /// cancelled when the pending state ends is view wiring with no UI test target.
    func testRemainingSendingRevealDelay_anchorsOnSendStartAndClamps() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertEqual(Policy.sendingRevealDelay, 0.7, accuracy: 0.0001)
        XCTAssertEqual(
            Policy.remainingSendingRevealDelay(pendingSince: start, now: start),
            0.7,
            accuracy: 0.0001
        )
        // A row rebuilt mid-send (scrolled away and back) waits only for what is left.
        XCTAssertEqual(
            Policy.remainingSendingRevealDelay(pendingSince: start, now: start.addingTimeInterval(0.5)),
            0.2,
            accuracy: 0.0001
        )
        // Long pending: show "Sending…" at once.
        XCTAssertEqual(
            Policy.remainingSendingRevealDelay(pendingSince: start, now: start.addingTimeInterval(5)),
            0,
            accuracy: 0.0001
        )
        // A clock that moved backwards never stretches the wait past the grace period.
        XCTAssertEqual(
            Policy.remainingSendingRevealDelay(pendingSince: start, now: start.addingTimeInterval(-30)),
            0.7,
            accuracy: 0.0001
        )
    }

    // MARK: - Sent receipt

    /// iMessage-style receipt: only under the conversation's newest message, only when it is the
    /// user's own, and only once Gmail accepted it.
    ///
    /// Revert-check: dropping the `isNewestInTranscript` condition in
    /// `MessageSendStatusLinePolicy.line` fails the older-row assertion; dropping `isFromMe` fails
    /// the incoming-row assertion.
    func testLine_acceptedOwnNewestRow_showsSentAndNoOtherRowDoes() {
        XCTAssertEqual(line(.none), .sent)
        XCTAssertEqual(Policy.Line.sent.label, "Sent")

        // A newer message arrived: the receipt leaves this row.
        XCTAssertNil(line(.none, isNewestInTranscript: false))
        // The newest row is someone else's.
        XCTAssertNil(line(.none, isFromMe: false))
    }

    /// `.none` is also the row mapper's fallback when an optimistic row's record fetch fails or
    /// finds nothing, so it alone must not produce "Sent": the receipt fails closed to no caption,
    /// as before receipts existed.
    ///
    /// Revert-check: dropping the `isConfirmedInGmail` condition in
    /// `MessageSendStatusLinePolicy.line` fails this test.
    func testLine_ownNewestRowWithoutGmailEvidence_showsNothing() {
        XCTAssertNil(line(.none, isConfirmedInGmail: false))
        XCTAssertNil(line(.none, isConfirmedInGmail: false, isNewestInTranscript: false))
        // The evidence never hides a real status.
        XCTAssertEqual(line(.notSent, isConfirmedInGmail: false), .notSent)
        XCTAssertEqual(line(.deliveryUnknown, isConfirmedInGmail: false), .deliveryUnknown)
    }

    /// Gmail may or may not have an ambiguous send; it must never read as Sent, on any row.
    ///
    /// Revert-check: mapping `.deliveryUnknown` to `.sent` (or `nil`) in
    /// `MessageSendStatusLinePolicy.line` fails this test.
    func testLine_deliveryUnknown_neverShowsSent() {
        for isNewest in [true, false] {
            for isRevealDue in [true, false] {
                XCTAssertEqual(
                    line(.deliveryUnknown, isSendingRevealDue: isRevealDue, isNewestInTranscript: isNewest),
                    .deliveryUnknown
                )
            }
        }
        XCTAssertEqual(Policy.Line.deliveryUnknown.label, "Delivery unknown")
    }

    func testLine_failuresShowOnEveryRowAndNeverAsSent() {
        for isNewest in [true, false] {
            XCTAssertEqual(line(.notSent, isNewestInTranscript: isNewest), .notSent)
            XCTAssertEqual(line(.sendFailed, isNewestInTranscript: isNewest), .sendFailed)
        }
        XCTAssertEqual(Policy.Line.notSent.label, "Not sent")
        XCTAssertEqual(Policy.Line.sendFailed.label, "Send failed")
    }

    /// At accessibility text sizes the caption gets its own line rather than being truncated
    /// beside the timestamp in the 280pt column.
    ///
    /// Revert-check: returning `.inline` for every size in
    /// `MessageSendStatusLinePolicy.arrangement` fails the accessibility-size assertion.
    ///
    /// HONEST SCOPE: pins the decision only. The inline order (caption ahead of the timestamp, so
    /// the timestamp's trailing edge stays put), the caption's layout priority, and the
    /// timestamp's one-line limit are `MessageBubble` view wiring with no UI test target.
    func testArrangement_accessibilityTextSize_stacksCaptionAboveTimestamp() {
        XCTAssertEqual(Policy.arrangement(isAccessibilityTextSize: false), .inline)
        XCTAssertEqual(Policy.arrangement(isAccessibilityTextSize: true), .stacked)
    }

    /// Revert-check: dropping the `isShowingLatestWindow` guard in
    /// `MessageSendStatusLinePolicy.newestRowIndex` fails the older-window assertion.
    func testNewestRowIndex_isLastRowOfLatestWindowOnly() {
        XCTAssertEqual(Policy.newestRowIndex(displayedRowCount: 20, isShowingLatestWindow: true), 19)
        // An older window's last row is not the conversation's newest message.
        XCTAssertNil(Policy.newestRowIndex(displayedRowCount: 20, isShowingLatestWindow: false))
        XCTAssertNil(Policy.newestRowIndex(displayedRowCount: 0, isShowingLatestWindow: true))
    }
}
