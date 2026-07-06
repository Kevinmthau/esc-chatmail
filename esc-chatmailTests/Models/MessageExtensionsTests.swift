import XCTest
import CoreData
@testable import esc_chatmail

final class MessageExtensionsTests: XCTestCase {
    private var testStack: TestCoreDataStack!
    private var context: NSManagedObjectContext!

    override func setUp() {
        super.setUp()
        testStack = TestCoreDataStack()
        context = testStack.viewContext
    }

    override func tearDown() {
        context = nil
        testStack = nil
        super.tearDown()
    }

    func testConversationPreviewText_forwardedMessage_usesQuotedOriginalSubject() {
        let message = MessageBuilder()
            .withSubject("Fwd: An exceptional chalet in Val d'Isere")
            .withSnippet("Body snippet")
            .build(in: context)
        message.chatPreviewText = "Chat preview should not win"

        XCTAssertEqual(message.conversationPreviewText, "Fwd: \"An exceptional chalet in Val d'Isere\"")
    }

    func testConversationPreviewText_forwardedMessage_stripsMultipleForwardPrefixes() {
        let message = MessageBuilder()
            .withSubject("FW: Fwd: Weekly update")
            .build(in: context)

        XCTAssertEqual(message.conversationPreviewText, "Fwd: \"Weekly update\"")
    }

    func testConversationPreviewText_newsletter_usesSubject() {
        let message = MessageBuilder()
            .asNewsletter()
            .withSubject("Big sale this weekend")
            .withSnippet("Snippet")
            .build(in: context)
        message.chatPreviewText = "Chat preview should not win"

        XCTAssertEqual(message.conversationPreviewText, "Big sale this weekend")
    }

    func testConversationPreviewText_regularMessage_prefersCleanedSnippet() {
        let message = MessageBuilder()
            .withSubject("Hello")
            .withSnippet("Raw snippet")
            .build(in: context)
        message.cleanedSnippet = "Clean snippet"

        XCTAssertEqual(message.conversationPreviewText, "Clean snippet")
    }

    func testConversationPreviewText_regularMessage_fallsBackToChatPreviewText() {
        let message = MessageBuilder()
            .withSubject("Subject fallback")
            .withSnippet(" \n\t ")
            .build(in: context)
        message.cleanedSnippet = nil
        message.chatPreviewText = "Canonical chat preview"

        XCTAssertEqual(message.conversationPreviewText, "Canonical chat preview")
    }

    func testConversationPreviewText_regularMessage_compactsMultilineChatPreviewText() {
        let message = MessageBuilder()
            .withSubject("Subject fallback")
            .withSnippet(" \n\t ")
            .build(in: context)
        message.cleanedSnippet = nil
        message.chatPreviewText = "Line one.\n\nLine two."

        XCTAssertEqual(message.conversationPreviewText, "Line one. Line two.")
    }

    func testConversationPreviewText_regularMessage_fallsBackToSubject() {
        let message = MessageBuilder()
            .withSubject("Subject fallback")
            .withSnippet(" \n\t ")
            .build(in: context)
        message.cleanedSnippet = nil
        message.chatPreviewText = " \n\t "

        XCTAssertEqual(message.conversationPreviewText, "Subject fallback")
    }

    func testHTMLDisplayCleanupMode_forwardedMessage_defaultsToNone() {
        let message = MessageBuilder()
            .withSubject("Fwd: Proposal")
            .build(in: context)

        XCTAssertEqual(message.htmlDisplayCleanupMode, .none)
    }

    func testHTMLDisplayCleanupMode_newsletter_defaultsToNone() {
        let message = MessageBuilder()
            .asNewsletter()
            .withSubject("Weekly digest")
            .build(in: context)

        XCTAssertEqual(message.htmlDisplayCleanupMode, .none)
    }

    func testHTMLDisplayCleanupMode_regularMessage_usesQuotedAndSignature() {
        let message = MessageBuilder()
            .withSubject("Re: Plans")
            .build(in: context)

        XCTAssertEqual(message.htmlDisplayCleanupMode, .quotedAndSignature)
    }

    func testHTMLDisplayCleanupMode_sentMessage_defaultsToNone() {
        let message = MessageBuilder()
            .fromMe()
            .withSubject("Re: Plans")
            .build(in: context)

        XCTAssertEqual(message.htmlDisplayCleanupMode, .none)
    }

    func testForwardedDisplaySubject_stripsForwardPrefix() {
        let message = MessageBuilder()
            .withSubject("FW: Fwd: Weekly update")
            .build(in: context)

        XCTAssertEqual(message.forwardedDisplaySubject, "Weekly update")
    }

    func testOutgoingForwardedDisplayContent_parsesStructuredSummary() {
        let message = MessageBuilder()
            .fromMe()
            .withSubject("Fwd: Spring plans")
            .withBody(
                """
                FYI

                ---------- Forwarded message ---------
                From: Jane Example &lt;jane@example.com&gt;
                Date: Mon, Feb 16, 2026 at 5:56 PM
                Subject: Spring plans
                To: me@example.com

                Looking forward to seeing you there.
                """
            )
            .build(in: context)

        XCTAssertEqual(message.outgoingForwardedDisplayContent?.leadInText, "FYI")
        XCTAssertEqual(message.outgoingForwardedDisplayContent?.senderDisplayName, "Jane Example")
        XCTAssertEqual(message.outgoingForwardedDisplayContent?.subject, "Spring plans")
        XCTAssertEqual(message.outgoingForwardedDisplayContent?.recipientSummary, "me@example.com")
        XCTAssertEqual(
            message.outgoingForwardedDisplayContent?.previewSnippet,
            "Looking forward to seeing you there."
        )
    }

    func testOutgoingForwardedDisplayContent_snippetFallback_parsesFlattenedHeaders() {
        let message = MessageBuilder()
            .fromMe()
            .withSubject("Fwd: Spring plans")
            .withSnippet(
                "FYI ---------- Forwarded message --------- From: Jane Example <jane@example.com> Date: Mon, Feb 16, 2026 at 5:56 PM Subject: Spring plans To: me@example.com, friend@example.com Looking forward to seeing you there."
            )
            .build(in: context)
        message.bodyText = nil

        XCTAssertEqual(message.outgoingForwardedDisplayContent?.leadInText, "FYI")
        XCTAssertEqual(message.outgoingForwardedDisplayContent?.senderDisplayName, "Jane Example")
        XCTAssertEqual(message.outgoingForwardedDisplayContent?.subject, "Spring plans")
        XCTAssertEqual(message.outgoingForwardedDisplayContent?.recipientSummary, "me@example.com +1")
        XCTAssertEqual(
            message.outgoingForwardedDisplayContent?.previewSnippet,
            "Looking forward to seeing you there."
        )
    }

    // MARK: - isLikelyCalendarInvite memoization

    func testIsLikelyCalendarInvite_memoRecomputesWhenContentBecomesInvite() throws {
        let message = MessageBuilder()
            .withId("memo-invite-\(UUID().uuidString)")
            .withSubject("Lunch?")
            .withBody("Want to grab food later?")
            .build(in: context)
        try testStack.saveViewContext()

        // Prime the memo with the non-invite result.
        XCTAssertFalse(message.isLikelyCalendarInvite)

        // Changing the signal inputs must invalidate the memo (fingerprint),
        // not return the stale cached value.
        message.subject = "Invitation: Board sync @ Mon May 5, 2026 9:00am - 9:30am (EDT)"
        message.bodyText = """
        Invitation from Google Calendar
        Board sync
        When
        Monday May 5, 2026 • 9:00am – 9:30am (Eastern Time - New York)
        Guests
        brynn@example.com
        """
        XCTAssertTrue(message.isLikelyCalendarInvite)
    }

    func testIsLikelyCalendarInvite_memoIsStableAcrossRepeatedReads() throws {
        let message = MessageBuilder()
            .withId("memo-stable-\(UUID().uuidString)")
            .withSubject("Invitation: Standup @ Tue May 6, 2026 10:00am - 10:15am (EDT)")
            .withBody("Invitation from Google Calendar\nStandup\nWhen\nTuesday May 6, 2026 10:00am")
            .build(in: context)
        try testStack.saveViewContext()

        let first = message.isLikelyCalendarInvite
        let second = message.isLikelyCalendarInvite
        XCTAssertEqual(first, second)
        XCTAssertTrue(first)
    }
}
