import XCTest
@testable import esc_chatmail

final class PlainTextQuoteRemoverTests: XCTestCase {

    // MARK: - Basic Functionality

    func testRemoveQuotes_nilInput_returnsNil() {
        let result = PlainTextQuoteRemover.removeQuotes(from: nil)
        XCTAssertNil(result)
    }

    func testRemoveQuotes_emptyString_returnsEmptyString() {
        let result = PlainTextQuoteRemover.removeQuotes(from: "")
        XCTAssertEqual(result, "")
    }

    func testRemoveQuotes_noQuotes_returnsOriginal() {
        let text = "Hello, this is a simple message without any quotes."
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, text)
    }

    func testRemoveQuotes_preservesBodyContent() {
        let text = """
        Hi there,

        Thanks for your email. I wanted to follow up on our conversation.

        Looking forward to hearing from you.
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertTrue(result?.contains("Thanks for your email") ?? false)
        XCTAssertTrue(result?.contains("Looking forward to hearing from you") ?? false)
    }

    // MARK: - Quote Removal - "On X wrote" Pattern

    func testRemoveQuotes_onWrotePattern_truncatesAtQuote() {
        let text = """
        Sounds good!

        On Monday, January 15, 2024, John Doe wrote:
        > Original message here
        > More quoted text
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "Sounds good!")
    }

    func testRemoveQuotes_onWrotePatternWithTime_truncates() {
        let text = """
        Got it, thanks!

        On Jan 15, 2024, at 10:30 AM, Jane Smith wrote:
        > Previous message content
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "Got it, thanks!")
    }

    func testRemoveQuotes_onWrotePatternCaseInsensitive_truncates() {
        let text = """
        Thanks!

        ON MONDAY, JOHN DOE WROTE:
        > Quoted content
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "Thanks!")
    }

    // MARK: - Quote Removal - Original Message Header

    func testRemoveQuotes_originalMessageHeader_truncates() {
        let text = """
        I agree with your proposal.

        -----Original Message-----
        From: John Doe
        Sent: Monday, January 15, 2024
        To: Jane Smith
        Subject: Re: Meeting

        Original message content here.
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "I agree with your proposal.")
    }

    func testRemoveQuotes_underscoreLine_truncates() {
        let text = """
        Let me know what you think.

        ________________________________
        From: sender@example.com
        To: recipient@example.com
        Subject: Re: Question
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "Let me know what you think.")
    }

    // MARK: - Quote Removal - Forwarded Messages

    func testRemoveQuotes_forwardedMessageMarker_truncates() {
        let text = """
        FYI - see below.

        Begin forwarded message:
        From: someone@example.com
        Subject: Important Info
        Date: January 15, 2024

        Forwarded content here.
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "FYI - see below.")
    }

    func testRemoveQuotes_forwardedMessageDashes_truncates() {
        let text = """
        Check this out!

        ---------- Forwarded message ---------
        From: John Doe
        To: Jane Smith

        Original message.
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "Check this out!")
    }

    // MARK: - Quote Removal - Consecutive Angle Bracket Quotes

    func testRemoveQuotes_consecutiveAngleBracketQuotes_truncates() {
        let text = """
        Yes, I can do that.

        > This is quoted text
        > More quoted text here
        > And even more
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "Yes, I can do that.")
    }

    func testRemoveQuotes_singleAngleBracketLine_doesNotTruncate() {
        let text = """
        Here's my response:

        > Just one quoted line is not enough to trigger removal

        More content after.
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        // Single quote line should be preserved (need 2+ consecutive)
        XCTAssertTrue(result?.contains("More content after") ?? false)
    }

    func testRemoveQuotes_nestedAngleBrackets_truncates() {
        let text = """
        Makes sense.

        >> Nested quote level 2
        >> More nested
        > Quote level 1
        > More level 1
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "Makes sense.")
    }

    // MARK: - Signature Removal - Standard Delimiters

    func testRemoveSignature_dashDashPattern_removes() {
        let text = """
        Thanks for your help!

        --
        John Doe
        Software Engineer
        john@example.com
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, "Thanks for your help!")
    }

    func testRemoveSignature_dashDashSpacePattern_removes() {
        let text = """
        See you tomorrow!

        --
        Jane Smith
        Product Manager
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, "See you tomorrow!")
    }

    func testRemoveSignature_tripleDashPattern_removes() {
        let text = """
        Got it.

        ---
        Signature content
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, "Got it.")
    }

    // MARK: - Signature Removal - Sign-offs

    func testRemoveSignature_thanksComma_removes() {
        let text = """
        I'll send that over now.

        Thanks,
        John
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, "I'll send that over now.")
    }

    func testRemoveSignature_bestRegards_removes() {
        let text = """
        Let me know if you need anything else.

        Best regards,
        Jane Doe
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, "Let me know if you need anything else.")
    }

    func testRemoveSignature_cheers_removes() {
        let text = """
        Sounds great!

        Cheers,
        Bob
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, "Sounds great!")
    }

    func testRemoveSignature_sincerely_removes() {
        let text = """
        Please review at your earliest convenience.

        Sincerely,
        Dr. Smith
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, "Please review at your earliest convenience.")
    }

    // MARK: - Signature Removal - Mobile Signatures

    func testRemoveSignature_sentFromIPhone_removes() {
        let text = """
        I'm on my way.

        Sent from my iPhone
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, "I'm on my way.")
    }

    func testRemoveSignature_sentFromAndroid_removes() {
        let text = """
        Running late, be there soon.

        Sent from my Android device
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, "Running late, be there soon.")
    }

    func testRemoveSignature_sentFromOutlook_removes() {
        let text = """
        Attached is the document.

        Sent from Outlook for iOS
        Get Outlook for Android
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, "Attached is the document.")
    }

    // MARK: - Signature Removal - Legal Disclaimers

    func testRemoveSignature_legalDisclaimer_removes() {
        let text = """
        Please find the report attached.

        This email and any attachments are confidential and intended solely for the addressee.
        If you have received this email in error, please notify the sender immediately.
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, "Please find the report attached.")
    }

    func testRemoveSignature_confidentialityNotice_removes() {
        let text = """
        Meeting is confirmed for 3pm.

        Confidentiality Notice: This message may contain privileged information.
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, "Meeting is confirmed for 3pm.")
    }

    // MARK: - Signature Removal - Unsubscribe Links

    func testRemoveSignature_unsubscribeLink_removes() {
        let text = """
        Check out our latest products!

        Unsubscribe from this mailing list
        Update your preferences
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, "Check out our latest products!")
    }

    func testRemoveSignature_receivingThisEmail_removes() {
        let text = """
        Your order has shipped!

        You are receiving this email because you signed up for notifications.
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, "Your order has shipped!")
    }

    // MARK: - Multiple Patterns

    func testRemoveQuotes_multiplePatterns_usesEarliest() {
        let text = """
        My response.

        On Jan 15, John wrote:
        > Quoted text

        -----Original Message-----
        More quoted content
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "My response.")
    }

    func testRemoveQuotes_quoteAndSignature_removesBoth() {
        let text = """
        Thanks for the update!

        Best regards,
        Jane

        On Monday, John wrote:
        > Previous message
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        // Should remove both the signature and the quote
        XCTAssertEqual(result, "Thanks for the update!")
    }

    // MARK: - Case Sensitivity

    func testRemoveSignature_caseInsensitive_works() {
        let text = """
        OK

        SENT FROM MY IPHONE
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, "OK")
    }

    func testRemoveQuotes_caseInsensitivePatterns_work() {
        let text = """
        Got it

        BEGIN FORWARDED MESSAGE:
        content
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "Got it")
    }

    // MARK: - Edge Cases

    func testRemoveQuotes_onlyQuotedContent_returnsEmpty() {
        let text = """
        On Jan 15, John wrote:
        > All quoted content
        > No original text
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "")
    }

    func testRemoveQuotes_whitespaceOnly_returnsEmpty() {
        let text = "   \n\n   "
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "")
    }

    func testRemoveQuotes_preservesIntentionalContent() {
        // Make sure we don't remove content that looks like signatures but is part of the message
        let text = "The thanks committee will meet at 3pm to discuss the best approach."
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, text)
    }

    func testRemoveSignature_signaturePatternMidSentence_notRemoved() {
        // "Thanks," at the start of a line triggers removal, but not mid-sentence
        let text = "I wanted to say thanks for your help with the project."
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, text)
    }

    func testRemoveQuotes_urlInBody_notRemovedIfNotOnNewLine() {
        // URLs on their own line trigger removal, but URLs in text should be preserved
        let text = "Check out our site at the link I shared."
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, text)
    }

    // MARK: - Real-World Examples

    func testRemoveQuotes_typicalReply_cleansCorrectly() {
        let text = """
        Hi John,

        Yes, that works for me. Let's schedule the call for 2pm tomorrow.

        Thanks,
        Jane

        On Mon, Jan 15, 2024 at 10:30 AM John Doe <john@example.com> wrote:
        > Hi Jane,
        >
        > Would tomorrow afternoon work for a quick call?
        >
        > Thanks,
        > John
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "Hi John,\n\nYes, that works for me. Let's schedule the call for 2pm tomorrow.")
    }

    func testRemoveQuotes_forwardedChain_cleansCorrectly() {
        let text = """
        Adding you to this thread for visibility.

        ---------- Forwarded message ---------
        From: Alice <alice@example.com>
        Date: Mon, Jan 15, 2024
        Subject: Project Update
        To: Bob <bob@example.com>

        The project is on track.
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "Adding you to this thread for visibility.")
    }

    func testRemoveQuotes_outlookStyle_cleansCorrectly() {
        let text = """
        Approved.

        ________________________________
        From: John Doe <john@example.com>
        Sent: Monday, January 15, 2024 10:30 AM
        To: Jane Smith <jane@example.com>
        Subject: Approval Request

        Please approve the attached document.
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "Approved.")
    }

    // MARK: - Apple Mail Style Quotes

    func testRemoveQuotes_appleMailStyle_withDate_cleansCorrectly() {
        let text = """
        Sounds good, I'll review the documents.

        From: Ally Varady <ally@cv-partners.com>
        Date: Thursday, January 15, 2026 at 9:23 AM
        To: Brynn Putnam <brynn.putnam@gmail.com>
        Subject: 1040 5th | AWO's for Approval

        Hi Brynn,

        Please find attached the documents for your review.
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "Sounds good, I'll review the documents.")
    }

    func testRemoveQuotes_appleMailStyle_withCc_cleansCorrectly() {
        let text = """
        Thanks for looping me in!

        From: Ally Varady <ally@cv-partners.com>
        Date: Thursday, January 15, 2026 at 9:23 AM
        To: Brynn Putnam <brynn.putnam@gmail.com>
        Cc: Victoria Stadlin <victoria@cv-partners.com>
        Subject: 1040 5th | AWO's for Approval

        Hi team,

        Please review the attached items.
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "Thanks for looping me in!")
    }

    func testRemoveQuotes_appleMailStyle_shortDate_cleansCorrectly() {
        let text = """
        Got it.

        From: John Doe <john@example.com>
        Date: Jan 15, 2026
        To: Jane Smith <jane@example.com>
        Subject: Quick question

        Original message here.
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "Got it.")
    }
}
