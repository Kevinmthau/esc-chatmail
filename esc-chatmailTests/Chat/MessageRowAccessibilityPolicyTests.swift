import XCTest
@testable import esc_chatmail

/// What a transcript row says before its content (architecture review 2026-11,
/// gap-accessibility-architecture#1). In the default plan and in `Mac.xctestplan`: the Mac's
/// one-to-one rows have no avatar and no name, so the label is their only direction cue.
///
/// HONEST SCOPE: these pin the policy. That the bubble's column combines its children and says
/// this first is pinned from source (`MessageRowAccessibilitySourceTests`); a test host is told
/// nothing of SwiftUI's accessibility tree, and VoiceOver has not been heard.
final class MessageRowAccessibilityPolicyTests: XCTestCase {
    /// A row of someone else's names them whether or not the row draws a name or an avatar:
    /// a mid-run row of a Mac one-to-one chat draws neither.
    ///
    /// Revert-check: returning nil for a row that is not the user's in
    /// `MessageRowAccessibilityPolicy.speaker` fails this.
    func testSpeaker_someoneElsesRow_namesTheSender() {
        XCTAssertEqual(
            MessageRowAccessibilityPolicy.speaker(
                isFromMe: false,
                loadedSenderName: "Alice Smith",
                headerSenderName: "Alice",
                senderEmail: "alice@example.com"
            ),
            "Alice Smith"
        )
    }

    /// Before the sender load lands the row has the header's name, else the address.
    ///
    /// Revert-check: dropping `headerSenderName` from the candidates in
    /// `MessageRowAccessibilityPolicy.speaker` fails the first assertion.
    func testSpeaker_beforeTheSenderLoad_fallsBackToTheHeaderNameThenTheAddress() {
        XCTAssertEqual(
            MessageRowAccessibilityPolicy.speaker(
                isFromMe: false,
                loadedSenderName: nil,
                headerSenderName: "Alice",
                senderEmail: "alice@example.com"
            ),
            "Alice"
        )
        XCTAssertEqual(
            MessageRowAccessibilityPolicy.speaker(
                isFromMe: false,
                loadedSenderName: "  ",
                headerSenderName: nil,
                senderEmail: "alice@example.com"
            ),
            "alice@example.com"
        )
        XCTAssertNil(
            MessageRowAccessibilityPolicy.speaker(
                isFromMe: false,
                loadedSenderName: nil,
                headerSenderName: nil,
                senderEmail: nil
            )
        )
    }

    /// The user's own row says "You" and its send state, then the time; the policy takes no
    /// content, so none can be said.
    ///
    /// Revert-check: the sender's name in place of "You" in
    /// `MessageRowAccessibilityPolicy.speaker`, or dropping `statusLabel` from
    /// `labelPrefix`, fails this.
    func testLabelPrefix_ownUnsentRow_saysYouNotSentAndTheTime() {
        let speaker = MessageRowAccessibilityPolicy.speaker(
            isFromMe: true,
            loadedSenderName: "Me Myself",
            headerSenderName: nil,
            senderEmail: "me@example.com"
        )

        XCTAssertEqual(
            MessageRowAccessibilityPolicy.labelPrefix(
                speaker: speaker,
                statusLabel: MessageSendStatusLinePolicy.Line.notSent.label,
                time: "2:41 PM"
            ),
            "You, Not sent, 2:41 PM"
        )
    }

    /// A row with no status line says who and when.
    ///
    /// Revert-check: `.map { $0 ?? "" }` in place of the nil and empty filtering in
    /// `MessageRowAccessibilityPolicy.labelPrefix` (an empty part between commas) fails this.
    func testLabelPrefix_noStatusLine_saysTheSpeakerAndTheTime() {
        XCTAssertEqual(
            MessageRowAccessibilityPolicy.labelPrefix(speaker: "Alice", statusLabel: nil, time: "Yesterday"),
            "Alice, Yesterday"
        )
        XCTAssertEqual(
            MessageRowAccessibilityPolicy.labelPrefix(speaker: nil, statusLabel: nil, time: "Yesterday"),
            "Yesterday"
        )
    }
}
