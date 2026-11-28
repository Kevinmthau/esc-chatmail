import XCTest
@testable import esc_chatmail

/// The transcript row's accessibility wiring, which only source shows (architecture review
/// 2026-11, gap-accessibility-architecture#1): the bubble's column is one element that says the
/// policy's prefix before its own text; the avatar, the sender's name and the metadata line are
/// hidden, because the prefix says them; the recovery badge and the Mac's time line stay
/// elements of their own.
///
/// HONEST SCOPE: this reads source text. What VoiceOver reads from these modifiers was not
/// heard, on iOS 18 and later, on iOS 17's custom-content path, or on the Mac. The prefix
/// itself is `MessageRowAccessibilityPolicyTests`'.
final class MessageRowAccessibilitySourceTests: XCTestCase {
    /// Revert-check: deleting `.accessibilityElement(children: .combine)` from the column in
    /// `MessageBubble` fails both assertions; `.accessibilityHint(accessibilityPrefix)` in
    /// place of the `MessageRowAccessibilityLabel` modifier fails the first (deleting it does
    /// not compile: the prefix is then unused, and warnings are errors).
    func testBubbleColumn_isOneElementWithThePrefixBeforeItsText() throws {
        let bubble = try repositorySource("esc-chatmail/Views/Chat/MessageBubble.swift")

        XCTAssertTrue(bubble.contains(
            "            .accessibilityElement(children: .combine)\n"
                + "            .modifier(MessageRowAccessibilityLabel(prefix: accessibilityPrefix))\n"
                + "            .frame(maxWidth: columnMaxWidth, alignment: message.isFromMe ? .trailing : .leading)\n"
        ))
        XCTAssertEqual(bubble.components(separatedBy: ".accessibilityElement(children: .combine)").count, 2)
    }

    /// The combined column ends before the recovery badge: combined with the row, the badge's
    /// dialog and the bubble's reader would be one activation, and the Mac's time line, drawn by
    /// the row's lead-in, would lose its header.
    ///
    /// Revert-check: moving the combine onto the row's `HStack` (after the recovery badge)
    /// fails this.
    func testBubbleColumn_combineEndsBeforeTheRecoveryBadgeAndTheTimeLine() throws {
        let bubble = try repositorySource("esc-chatmail/Views/Chat/MessageBubble.swift")
        let combine = try XCTUnwrap(bubble.range(of: ".accessibilityElement(children: .combine)"))
        let badge = try XCTUnwrap(bubble.range(of: "sendRecoveryBadge(prompt: recoveryPrompt, statusLine: statusLine)"))
        let leadIn = try XCTUnwrap(bubble.range(of: ".modifier(ChatTranscriptRowLeadIn(style: style, placement: runPlacement))"))

        XCTAssertLessThan(combine.lowerBound, badge.lowerBound)
        XCTAssertLessThan(combine.lowerBound, leadIn.lowerBound)
    }

    /// What the prefix says is hidden where it is drawn.
    ///
    /// Revert-check: deleting the `.accessibilityHidden(true)` after `leadingContent`,
    /// `senderNameView` or the `metadataLine(` call in `MessageBubble` fails this.
    func testBubble_avatarSenderNameAndMetadata_areHidden() throws {
        let bubble = try repositorySource("esc-chatmail/Views/Chat/MessageBubble.swift")

        XCTAssertTrue(bubble.contains(
            "                leadingContent\n"
                + "                    // The column's label names the sender (`MessageRowAccessibilityPolicy`).\n"
                + "                    .accessibilityHidden(true)\n"
        ))
        XCTAssertTrue(bubble.contains(
            "                senderNameView\n"
                + "                    .accessibilityHidden(true)\n"
        ))
        XCTAssertTrue(bubble.contains(
            "                metadataLine(statusLine: statusLine, sendStatus: sendStatus)\n"
                + "                    // Its status and time are the column label's prefix.\n"
                + "                    .accessibilityHidden(true)\n"
        ))
    }

    /// The prefix is built from the speaker, the status line and the visible timestamp's own
    /// formatter, and from no content field.
    ///
    /// Revert-check: passing `message.subject` or a body field into
    /// `MessageRowAccessibilityPolicy.labelPrefix` in `MessageBubble` fails this.
    func testBubblePrefix_isBuiltFromNoContentField() throws {
        let bubble = try repositorySource("esc-chatmail/Views/Chat/MessageBubble.swift")
        let start = try XCTUnwrap(bubble.range(of: "let accessibilityPrefix = MessageRowAccessibilityPolicy.labelPrefix("))
        let end = try XCTUnwrap(bubble.range(of: "time: TimestampFormatter.format(message.internalDate)\n        )", range: start.upperBound..<bubble.endIndex))
        let call = bubble[start.lowerBound..<end.upperBound]

        for contentField in ["subject", "bodyText", "chatPreviewText", "snippet", "fullTextContent", "fallbackPreviewText"] {
            XCTAssertFalse(call.contains(contentField), "\(contentField) in \(call)")
        }
    }
}
