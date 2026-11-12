import SwiftUI
import XCTest
@testable import esc_chatmail

/// The bubble styles' values (`MessageBubbleStyle`). Plain values, so these run in the iOS
/// suite and in `Mac.xctestplan`.
///
/// The Mac's transcript is a style of its own, and the rule of that work is that the iPhone's
/// does not move (`docs/mac-imessage-ui-plan.md`, PR 4). The first test holds `.standard` to
/// the numbers the bubble drew with before the Mac's style existed, written out again here,
/// and to "off" for everything that style added.
///
/// HONEST SCOPE: these pin the values, not that `MessageBubble` reads each where it used the
/// old one. That was checked once by drawing iOS rows before and after the change and
/// comparing the pixels (`docs/mac-imessage-ui-plan.md`, "PR 4 as built").
@MainActor
final class MessageBubbleStyleTests: XCTestCase {
    /// Revert-check: changing any `.standard` value in `MessageBubbleStyle` makes this fail.
    func testStandard_isTheBubbleFromBeforeTheMacHadAStyle() {
        let style = MessageBubbleStyle.standard

        XCTAssertTrue(style.showAvatar)
        XCTAssertTrue(style.showSenderName)
        XCTAssertTrue(style.showUnreadIndicator)
        XCTAssertTrue(style.showAttachmentGrid)
        XCTAssertNil(style.textLineLimit)
        XCTAssertEqual(style.maxBubbleWidth, 280)
        XCTAssertEqual(style.bubbleCornerRadius, 12)
        XCTAssertEqual(style.bubblePadding, EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
        XCTAssertEqual(style.senderBubbleColor(), .blue)
        XCTAssertEqual(style.recipientBubbleColor(), Color.gray.opacity(0.2))
        XCTAssertEqual(style.textColor(isFromMe: true), .white)
        XCTAssertEqual(style.textColor(isFromMe: false), .primary)

        // Everything the Mac's style added is off: no tail, the stack's old spacing, no run
        // padding, the timestamp under the bubble, no time lines, no large emoji, and widths
        // that do not follow the transcript.
        XCTAssertEqual(style.bubbleTailWidth, 0)
        XCTAssertEqual(style.rowSpacing, 8)
        XCTAssertEqual(style.runTopPadding, 0)
        XCTAssertTrue(style.showsTimestampUnderBubble)
        XCTAssertFalse(style.showsTimestampSeparators)
        XCTAssertFalse(style.drawsLargeEmoji)
        XCTAssertNil(style.textBubbleWidthShare)
        XCTAssertNil(style.imageMaxWidth)
    }

    /// Revert-check: giving `.standard` a `textBubbleWidthShare` makes this fail: the iPhone's
    /// bubbles would follow the transcript's width.
    func testStandard_textBubbleWidth_isTheFixedCapAtEveryTranscriptWidth() {
        for width: CGFloat in [0, 320, 393, 1024, 2000] {
            XCTAssertEqual(MessageBubbleStyle.standard.textBubbleMaxWidth(transcriptWidth: width), 280)
        }
    }

    /// Revert-check: changing any `.mac` value in `MessageBubbleStyle` makes this fail.
    func testMac_isMessagesTranscript() {
        let style = MessageBubbleStyle.mac

        XCTAssertTrue(style.showAvatar)
        XCTAssertTrue(style.showSenderName)
        XCTAssertFalse(style.showUnreadIndicator)
        XCTAssertTrue(style.showAttachmentGrid)
        XCTAssertNil(style.textLineLimit)
        XCTAssertEqual(style.maxBubbleWidth, 280)
        XCTAssertEqual(style.bubbleCornerRadius, 17)
        XCTAssertEqual(style.bubblePadding, EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        XCTAssertEqual(style.senderBubbleColor(), .blue)
        // Opaque: a translucent fill would show the tail darker where it overlaps the bubble.
        XCTAssertEqual(style.recipientBubbleColor(), Color.systemGray5)
        XCTAssertEqual(style.bubbleTailWidth, 4)
        XCTAssertEqual(style.rowSpacing, 2)
        XCTAssertEqual(style.runTopPadding, 8)
        XCTAssertFalse(style.showsTimestampUnderBubble)
        XCTAssertTrue(style.showsTimestampSeparators)
        XCTAssertTrue(style.drawsLargeEmoji)
        XCTAssertEqual(style.textBubbleWidthShare, 0.65)
        XCTAssertEqual(style.imageMaxWidth, 400)
    }

    /// Revert-check: returning `maxBubbleWidth` for every style from
    /// `MessageBubbleStyle.textBubbleMaxWidth` makes the wide-transcript assertions fail;
    /// dropping its `max(maxBubbleWidth, …)` makes the narrow one fail.
    func testMac_textBubbleWidth_followsTheTranscriptAndIsNeverNarrowerThanACard() {
        let style = MessageBubbleStyle.mac

        XCTAssertEqual(style.textBubbleMaxWidth(transcriptWidth: 1000), 650)
        XCTAssertEqual(style.textBubbleMaxWidth(transcriptWidth: 701), 455)
        // A narrow chat column: the share alone would be 195 points.
        XCTAssertEqual(style.textBubbleMaxWidth(transcriptWidth: 300), 280)
        // Before the transcript has a width.
        XCTAssertEqual(style.textBubbleMaxWidth(transcriptWidth: 0), 280)
        XCTAssertEqual(style.textBubbleMaxWidth(transcriptWidth: .infinity), 280)
    }

    /// The Mac's chat column can be narrower than the style's image width: the window's
    /// minimum is 700 points and the sidebar takes up to 480 of them. A row holding a
    /// 400-point image was then wider than the transcript and was cut off at both edges.
    ///
    /// Revert-check: returning `imageMaxWidth` from
    /// `MessageBubbleStyle.imageMaxWidth(transcriptWidth:)` at every width makes the narrow
    /// assertions fail; dropping its `max(Self.minimumImageMaxWidth, …)` makes the 150-point
    /// one fail.
    ///
    /// HONEST SCOPE: this pins the number the row is given. That the row then fits its column
    /// rests on `imageRowChromeWidth`, which was added up from the views' numbers and has not
    /// been measured or seen in the app.
    func testMac_imageWidth_isTheStylesCapWhereItFitsAndWhatTheColumnHasLeftWhereItDoesNot() {
        let style = MessageBubbleStyle.mac

        XCTAssertEqual(style.imageMaxWidth(transcriptWidth: 900), 400)
        XCTAssertEqual(style.imageMaxWidth(transcriptWidth: 496), 400)
        // The window at its minimum with the sidebar at its ideal width.
        XCTAssertEqual(style.imageMaxWidth(transcriptWidth: 380), 284)
        // The sidebar at its widest.
        XCTAssertEqual(style.imageMaxWidth(transcriptWidth: 220), 124)
        XCTAssertEqual(style.imageMaxWidth(transcriptWidth: 150), 120)
        // Before the transcript has a width.
        XCTAssertEqual(style.imageMaxWidth(transcriptWidth: 0), 400)
        XCTAssertEqual(style.imageMaxWidth(transcriptWidth: .infinity), 400)
    }

    /// Revert-check: giving `.standard` an `imageMaxWidth` makes this fail: the iPhone's
    /// images would leave `ImageAttachmentBubble`'s own cap.
    func testStandard_imageWidth_isTheImageBubblesOwnCapAtEveryTranscriptWidth() {
        for width: CGFloat in [0, 320, 393, 1024] {
            XCTAssertNil(MessageBubbleStyle.standard.imageMaxWidth(transcriptWidth: width))
        }
    }
}
