import XCTest
@testable import esc_chatmail

final class ForwardedMessageDisplayParserTests: XCTestCase {
    func testParseOutgoingForward_dashedMarker_extractsStructuredSummary() {
        let result = ForwardedMessageDisplayParser.parseOutgoingForward(
            from: """
            Check this out

            ---------- Forwarded message ---------
            From: Jane Example &lt;jane@example.com&gt;
            Date: Mon, Feb 16, 2026 at 5:56 PM
            Subject: Spring plans
            To: me@example.com, friend@example.com

            Looking forward to seeing you there.
            """
        )

        XCTAssertEqual(result?.leadInText, "Check this out")
        XCTAssertEqual(result?.senderDisplayName, "Jane Example")
        XCTAssertEqual(result?.senderEmail, "jane@example.com")
        XCTAssertEqual(result?.subject, "Spring plans")
        XCTAssertEqual(result?.recipientSummary, "me@example.com +1")
        XCTAssertEqual(result?.previewSnippet, "Looking forward to seeing you there.")
        XCTAssertTrue(result?.timestampText?.contains("Feb 16") == true)
        XCTAssertTrue(result?.timestampText?.contains("5:56") == true)
    }

    func testParseOutgoingForward_beginMarker_handlesBlankLineAndFallbackSender() {
        let result = ForwardedMessageDisplayParser.parseOutgoingForward(
            from: """
            Begin forwarded message:

            From: &lt;updates@example.com&gt;
            Date: Tue, Mar 4, 2025 9:15 AM
            Subject: Status update
            To: Team Example &lt;team@example.com&gt;

            Status update attached for review.
            """
        )

        XCTAssertNil(result?.leadInText)
        XCTAssertEqual(result?.senderDisplayName, "updates@example.com")
        XCTAssertEqual(result?.senderEmail, "updates@example.com")
        XCTAssertEqual(result?.subject, "Status update")
        XCTAssertEqual(result?.recipientSummary, "Team Example")
        XCTAssertEqual(result?.previewSnippet, "Status update attached for review.")
        XCTAssertTrue(result?.timestampText?.contains("Mar 4") == true)
        XCTAssertTrue(result?.timestampText?.contains("2025") == true)
        XCTAssertTrue(result?.timestampText?.contains("9:15") == true)
    }

    func testParseOutgoingForward_weirdHeaderPrefixStillParsesFromLine() {
        let result = ForwardedMessageDisplayParser.parseOutgoingForward(
            from: """
            FYI

            ---------- Forwarded message
            -------- From: The River Club of NY, Inc &lt;events@example.com&gt;
            Date: Mon, Feb 16, 2026 at 5:56 PM
            Subject: Member Event Confirmation

            Event details below.
            """
        )

        XCTAssertEqual(result?.senderDisplayName, "The River Club of NY, Inc")
        XCTAssertEqual(result?.senderEmail, "events@example.com")
        XCTAssertEqual(result?.subject, "Member Event Confirmation")
        XCTAssertEqual(result?.previewSnippet, "Event details below.")
    }

    func testParseOutgoingForward_inlineSnippetMarker_extractsStructuredSummary() {
        let result = ForwardedMessageDisplayParser.parseOutgoingForward(
            from: """
            FYI ---------- Forwarded message --------- From: Jane Example <jane@example.com> Date: Mon, Feb 16, 2026 at 5:56 PM Subject: Spring plans To: me@example.com, friend@example.com Looking forward to seeing you there.
            """
        )

        XCTAssertEqual(result?.leadInText, "FYI")
        XCTAssertEqual(result?.senderDisplayName, "Jane Example")
        XCTAssertEqual(result?.senderEmail, "jane@example.com")
        XCTAssertEqual(result?.subject, "Spring plans")
        XCTAssertEqual(result?.recipientSummary, "me@example.com +1")
        XCTAssertEqual(result?.previewSnippet, "Looking forward to seeing you there.")
        XCTAssertTrue(result?.timestampText?.contains("Feb 16") == true)
        XCTAssertTrue(result?.timestampText?.contains("5:56") == true)
    }

    func testParseOutgoingForward_quotedRecipientNames_doNotSplitOnDisplayNameCommas() {
        let result = ForwardedMessageDisplayParser.parseOutgoingForward(
            from: """
            ---------- Forwarded message ---------
            From: Jane Example <jane@example.com>
            Date: Mon, Feb 16, 2026 at 5:56 PM
            Subject: Spring plans
            To: "Doe, Jane" <jane@example.com>, john@example.com

            Looking forward to seeing you there.
            """
        )

        XCTAssertEqual(result?.recipientSummary, "Doe, Jane +1")
    }

    func testParseOutgoingForward_withoutForwardMarker_returnsNil() {
        XCTAssertNil(
            ForwardedMessageDisplayParser.parseOutgoingForward(
                from: "Just a normal outgoing message."
            )
        )
    }
}
