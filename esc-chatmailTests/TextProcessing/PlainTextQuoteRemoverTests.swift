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

    func testRemoveQuotes_appleMailReplyWithSecondGreeting_preservesQuestions() {
        let text = """
        Hi Kevin,

        We can check and get back to you tomorrow.

        Hi Mallory,

        How many miles does the car have now? Where is it located?

        Thanks,
        David

        > On Feb 15, 2026, at 4:36 PM, Kevin wrote:
        > Hi David,
        > Would it be possible to turn in Mallory's 2023 Bronco early?
        > Thank you!
        """

        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertTrue(result?.contains("Hi Mallory,") ?? false, "Unexpected result: \(result ?? "nil")")
        XCTAssertTrue(result?.contains("How many miles does the car have now?") ?? false, "Unexpected result: \(result ?? "nil")")
        XCTAssertFalse(result?.contains("On Feb 15, 2026") ?? true, "Unexpected result: \(result ?? "nil")")
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

    func testRemoveQuotes_forwardedMessageWithoutTrailingDashes_truncates() {
        let text = """
        FYI

        ---------- Forwarded message
        -------- From: The River Club of NY, Inc <events@example.com>
        Date: Mon, Feb 16, 2026 at 5:56 PM
        Subject: Member Event Confirmation
        To: jess@example.com
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "FYI")
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

    // MARK: - Signature Removal - Sign-offs (Context-Aware)

    // Simple sign-offs without strong indicators should NOT truncate
    // (they're legitimate message closings, not signatures)

    func testRemoveSignature_thanksComma_preservedWithoutStrongIndicator() {
        let text = """
        I'll send that over now.

        Thanks,
        John
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        // Should preserve the closing - it's just a name, not a signature block
        XCTAssertEqual(result, "I'll send that over now.\n\nThanks,\nJohn")
    }

    func testRemoveSignature_thanksComma_removesWithStrongIndicator() {
        let text = """
        I'll send that over now.

        Thanks,
        John Doe
        Mobile: 555-1234
        john@example.com
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        // Should truncate because "Mobile:" is a strong signature indicator
        XCTAssertEqual(result, "I'll send that over now.")
    }

    func testRemoveSignature_multiParagraphBodyWithThanksAndName_stripsClosingButPreservesBody() {
        let text = """
        Hi Kevin,

        We can check and get back to you tomorrow.

        Hi Mallory,

        How many miles does the car have now? Where is it located?

        Thanks,
        David
        """

        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertTrue(result.contains("Hi Mallory,"), "Unexpected result: \(result)")
        XCTAssertTrue(result.contains("How many miles does the car have now?"), "Unexpected result: \(result)")
    }

    func testRemoveSignature_bestRegards_preservedWithoutStrongIndicator() {
        let text = """
        Let me know if you need anything else.

        Best regards,
        Jane Doe
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        // Should preserve - just a name after sign-off
        XCTAssertEqual(result, "Let me know if you need anything else.\n\nBest regards,\nJane Doe")
    }

    func testRemoveSignature_bestRegards_removesWithURL() {
        let text = """
        Let me know if you need anything else.

        Best regards,
        Jane Doe
        www.example.com
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        // Should truncate because URL is a strong indicator
        XCTAssertEqual(result, "Let me know if you need anything else.")
    }

    func testRemoveSignature_singleTrailingURLWithoutSignatureContext_preserved() {
        let text = """
        Here is the link you asked for:
        www.example.com
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, "Here is the link you asked for:\nwww.example.com")
    }

    func testRemoveSignature_phoneNumberInBodySentence_preserved() {
        let text = """
        Hi,

        Monday at 10am is great. Feel free to call me on my mobile 415-314-9804.

        Thank you,

        Kevin
        """

        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, """
        Hi,

        Monday at 10am is great. Feel free to call me on my mobile 415-314-9804.

        Thank you,

        Kevin
        """)
    }

    func testRemoveSignature_cheers_preservedWithoutStrongIndicator() {
        let text = """
        Sounds great!

        Cheers,
        Bob
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        // Should preserve - just a name
        XCTAssertEqual(result, "Sounds great!\n\nCheers,\nBob")
    }

    func testRemoveSignature_cheers_removesWithDisclaimer() {
        let text = """
        Sounds great!

        Cheers,
        Bob

        This email and any attachments are confidential.
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        // Should truncate because disclaimer is a strong indicator
        XCTAssertEqual(result, "Sounds great!")
    }

    func testRemoveSignature_contactBlockWithAddressAndPhone_removes() {
        let text = """
        Let me know.

        Thanks!

        Katie McGee
        S.R. Gambrel Inc.
        15 Watts Street, 4th Floor
        New York, NY 10013
        212-925-3380
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, "Let me know.\n\nThanks!")
    }

    func testRemoveSignature_delimiterAfterThankYouPreservesSignOffAndBody() {
        let text = """
        Hello,

        Sorry to miss your message. I am away from the office returning on
        Tuesday (2/17)

        If this matter is urgent, please contact:
        - Shane Cumings at shane.cumings@adviceperiod.com or (424) 394-1922
        - Victoria Hannon at victoria.hannon@adviceperiod.com or (312) 348-5477

        Thank you,

        Dominic

        --

        [image: Company logo] <http://adviceperiod.com>
        Dominic Cozzetto, CFA
        Partner Advisor
        dominic.cozzetto@adviceperiod.com
        Direct: (949) 407-8746
        Mobile: (206) 965-0877
        """

        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, """
        Hello,

        Sorry to miss your message. I am away from the office returning on
        Tuesday (2/17)

        If this matter is urgent, please contact:
        - Shane Cumings at shane.cumings@adviceperiod.com or (424) 394-1922
        - Victoria Hannon at victoria.hannon@adviceperiod.com or (312) 348-5477

        Thank you,

        Dominic
        """)
    }

    func testRemoveSignature_multiPartLawFirmBlockWithInternalBlankLine_removesEntireBlock() {
        let text = """
        Hi Kevin,

        The estimated payout figure was changed to $30 million-please see attached.

        Example LLP
        Monica Example
        Partner | Certified Family Law Specialist
        T (415) 227-3629

        monica@examplelaw.com<mailto:monica@examplelaw.com>
        425 Market Street, Suite 2900
        San Francisco, CA 94105
        www.examplelaw.com<http://www.examplelaw.com>
        """

        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, """
        Hi Kevin,

        The estimated payout figure was changed to $30 million-please see attached.
        """)
    }

    func testRemoveSignature_multiPartLawFirmBlockWithBarePhoneLabelLine_removesEntireBlock() {
        let text = """
        Hi Kevin,

        The estimated payout figure was changed to $30 million-please see attached.

        Example LLP
        Monica Example
        Partner | Certified Family Law Specialist
        T

        monica@examplelaw.com<mailto:monica@examplelaw.com>
        425 Market Street, Suite 2900
        San Francisco, CA 94105
        www.examplelaw.com<http://www.examplelaw.com>
        """

        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, """
        Hi Kevin,

        The estimated payout figure was changed to $30 million-please see attached.
        """)
    }

    func testRemoveSignature_sincerely_preservedWithoutStrongIndicator() {
        let text = """
        Please review at your earliest convenience.

        Sincerely,
        Dr. Smith
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        // Should preserve - just a name
        XCTAssertEqual(result, "Please review at your earliest convenience.\n\nSincerely,\nDr. Smith")
    }

    func testRemoveSignature_sincerely_removesWithPhoneNumber() {
        let text = """
        Please review at your earliest convenience.

        Sincerely,
        Dr. Smith
        T: 555-123-4567
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        // Should truncate because phone prefix is a strong indicator
        XCTAssertEqual(result, "Please review at your earliest convenience.")
    }

    func testRemoveSignature_multipleOccurrencesOfSameSignOff_findsLaterOneWithIndicator() {
        let text = """
        First section content.

        Thanks,
        Alice

        Second section content.

        Thanks,
        Bob
        Mobile: 555-1234
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        // First "Thanks," has no strong indicator, so it's preserved
        // Second "Thanks," has phone number indicator, so it triggers truncation
        XCTAssertEqual(result, "First section content.\n\nThanks,\nAlice\n\nSecond section content.")
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

    func testRemoveSignature_underscoreDelimiter_removes() {
        let text = """
        Thank you! Have a great weekend.

        ___________________________
        Jasmine Abouzied Shapiro
        Managing Director
        J.P. Morgan Private Bank
        270 Park Avenue, Floor 22
        New York, NY 10017
        212 464 1041
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, "Thank you! Have a great weekend.")
    }

    func testRemoveSignature_longCorporateDisclaimerTail_removesSignatureBlock() {
        let text = """
        Hi Kevin,

        Do you have some time to connect on lending solutions before 1pm tomorrow? Let us know what would work best for you.

        Jasmine

        Jasmine Abouzied Shapiro (she/her/hers) | Managing Director | J.P. Morgan Private Bank | 270 Park Avenue, Floor 22 | New York, NY 10017 | T: 212 464 1041
        M: +1 917-279-0105 | NMLS ID 093744 | jasmine.c.abouzied@jpmorgan.com | privatebank.jpmorgan.com

        J.P. Morgan Securities LLC | JPMorgan Chase Bank, N.A.

        Our Form CRS and Guide to Investment Services contain important information about the ways we can serve you and the products we offer.
        This communication is provided for informational purposes and is not an account statement.
        Please refer to your monthly statements for the official record of account activity.
        Questions should be directed to your J.P. Morgan representative.
        You should consult your own tax, legal, and accounting advisors before engaging in financial transactions.
        Please submit personal information through secure channels available to clients.
        Investment products involve risk and may lose value.
        No bank guarantee is provided for investment products discussed in this message.
        This material is intended solely for the recipient and related authorized parties.
        Distribution to unintended recipients is restricted by policy.
        Any forwarding should comply with firm communication standards.
        Payment details should always be confirmed by phone using a known number.
        If funds were sent to an unintended account, contact your team immediately.
        Additional disclosures may apply based on account type and jurisdiction.
        Product availability depends on review and approval requirements.
        Services described may vary by location and client eligibility.
        Historical references do not guarantee future performance.
        Terms may be updated periodically without prior notice.
        Use of electronic communication is subject to monitoring and retention rules.
        This message may include privileged information under applicable law.
        If you are not the intended recipient, please delete and notify the sender.
        """

        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, """
        Hi Kevin,

        Do you have some time to connect on lending solutions before 1pm tomorrow? Let us know what would work best for you.

        Jasmine
        """)
    }

    func testRemoveSignature_truncatedCorporateSnippet_removesVisibleSignatureLines() {
        let text = """
        Hi Kevin,

        Do you have some time to connect on lending solutions before 1pm tomorrow? Let us know what would work best for you.

        Jasmine

        Jasmine Abouzied Shapiro (she/her/hers) | Managing
        """

        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, """
        Hi Kevin,

        Do you have some time to connect on lending solutions before 1pm tomorrow? Let us know what would work best for you.

        Jasmine
        """)
    }

    func testRemoveSignature_truncatedCorporateSnippet_withUnicodeSeparators_removesVisibleSignatureLines() {
        let text = """
        Hi Kevin,

        Do you have some time to connect on lending solutions before 1pm tomorrow? Let us know what would work best for you.

        Jasmine

        Jasmine Abouzied Shapiro (she/her/hers) │ Managing
        """

        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, """
        Hi Kevin,

        Do you have some time to connect on lending solutions before 1pm tomorrow? Let us know what would work best for you.

        Jasmine
        """)
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

    func testRemoveSignature_outlookElectronicMailTransmissionDisclaimer_removes() {
        let text = """
        Thank you!

        This electronic mail transmission may contain confidential or privileged information. If you believe you have received this message in error, please notify the sender by reply transmission and delete the message without copying or disclosing it.
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, "Thank you!")
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
        Tel: 555-1234

        On Monday, John wrote:
        > Previous message
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        // Should remove both the signature (has phone indicator) and the quote
        XCTAssertEqual(result, "Thanks for the update!")
    }

    func testRemoveQuotes_quoteWithSimpleSignOff_preservesSignOff() {
        let text = """
        Thanks for the update!

        Best regards,
        Jane

        On Monday, John wrote:
        > Previous message
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        // Simple sign-off without strong indicator should be preserved
        // Quote is still removed
        XCTAssertEqual(result, "Thanks for the update!\n\nBest regards,\nJane")
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
        // Simple "Thanks,\nJane" closing is preserved (no strong signature indicator)
        // Quote is still removed
        XCTAssertEqual(result, "Hi John,\n\nYes, that works for me. Let's schedule the call for 2pm tomorrow.\n\nThanks,\nJane")
    }

    func testRemoveQuotes_typicalReplyWithSignature_cleansCorrectly() {
        let text = """
        Hi John,

        Yes, that works for me. Let's schedule the call for 2pm tomorrow.

        Thanks,
        Jane
        Mobile: 555-9876

        On Mon, Jan 15, 2024 at 10:30 AM John Doe <john@example.com> wrote:
        > Hi Jane,
        >
        > Would tomorrow afternoon work for a quick call?
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        // "Thanks,\nJane" with phone number IS a signature
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

    func testRemoveQuotes_outlookStyle_withCc_cleansCorrectly() {
        let text = """
        I have a wake to attend tomorrow evening unfortunately

        From: Dominic Cozzetto <dominic.cozzetto@adviceperiod.com>
        Sent: Wednesday, February 11, 2026 12:18 PM
        To: Flock, Kathleen <kathleen.flock@bofa.com>; Rory Gildea <rgildea@gi-cpas.com>
        Cc: Brynn Putnam <brynn.putnam@gmail.com>; Kevin Thau <kmthau@gmail.com>
        Subject: BofA Intro & Next Steps

        Hello Kathy & Rory,

        Kevin and Brynn would like to move forward with a call to meet Kathy and discuss next steps.
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "I have a wake to attend tomorrow evening unfortunately")
    }

    func testRemoveQuotes_outlookStyle_headersWithBlankLinesAndNoSubject_truncates() {
        let text = """
        Great. Will do! Have a nice weekend!

        From: Kevin Thau
        <kmthau@gmail.com>

        Sent: Saturday, February 14, 2026 3:17:13 PM

        To: Abouzied, Jasmine C (WM, USA)
        <jasmine.c.abouzied@jpmorgan.com>
        """

        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "Great. Will do! Have a nice weekend!")
    }

    func testRemoveQuotes_signatureWithInternalBlankLineBeforeOutlookHeaders_removesSignatureAndQuote() {
        let text = """
        Hi Kevin,

        The estimated payout figure was changed to $30 million-please see attached.

        Example LLP
        Monica Example
        Partner | Certified Family Law Specialist
        T (415) 227-3629

        monica@examplelaw.com<mailto:monica@examplelaw.com>
        425 Market Street, Suite 2900
        San Francisco, CA 94105
        www.examplelaw.com<http://www.examplelaw.com>

        From: Kevin Example <kevin@example.com>
        Sent: Thursday, February 12, 2026 12:45 PM
        To: Monica Example <monica@examplelaw.com>
        Subject: Re: Draft Settlement Letter

        Thanks for sending this over.
        """

        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, """
        Hi Kevin,

        The estimated payout figure was changed to $30 million-please see attached.
        """)
    }

    func testRemoveQuotes_signatureWithBarePhoneLabelBeforeOutlookHeaders_removesSignatureAndQuote() {
        let text = """
        Hi Kevin,

        The estimated payout figure was changed to $30 million-please see attached.

        Example LLP
        Monica Example
        Partner | Certified Family Law Specialist
        T

        monica@examplelaw.com<mailto:monica@examplelaw.com>
        425 Market Street, Suite 2900
        San Francisco, CA 94105
        www.examplelaw.com<http://www.examplelaw.com>

        From: Kevin Example <kevin@example.com>
        Sent: Thursday, February 12, 2026 12:45 PM
        To: Monica Example <monica@examplelaw.com>
        Subject: Re: Draft Settlement Letter

        Thanks for sending this over.
        """

        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, """
        Hi Kevin,

        The estimated payout figure was changed to $30 million-please see attached.
        """)
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

    // MARK: - International Quote Patterns

    func testRemoveQuotes_germanPattern_schrieb_cleansCorrectly() {
        let text = """
        Danke für die Nachricht!

        Am 15. Januar 2024 schrieb Hans Müller:
        > Hallo,
        > Hier ist der Bericht.
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "Danke für die Nachricht!")
    }

    func testRemoveQuotes_germanHeader_cleansCorrectly() {
        let text = """
        In Ordnung.

        Von: Hans Müller <hans@example.de>
        Gesendet: Montag, 15. Januar 2024
        An: Maria Schmidt <maria@example.de>
        Betreff: Re: Projekt

        Original text here.
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "In Ordnung.")
    }

    func testRemoveQuotes_frenchPattern_aEcrit_cleansCorrectly() {
        let text = """
        Merci beaucoup!

        Le 15 janvier 2024, Jean Dupont a écrit :
        > Bonjour,
        > Voici le rapport.
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "Merci beaucoup!")
    }

    func testRemoveQuotes_spanishPattern_escribio_cleansCorrectly() {
        let text = """
        Gracias por la información.

        El 15 de enero de 2024, Carlos García escribió:
        > Hola,
        > Aquí está el informe.
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "Gracias por la información.")
    }

    func testRemoveQuotes_italianPattern_haScritto_cleansCorrectly() {
        let text = """
        Grazie mille!

        Il 15 gennaio 2024, Marco Rossi ha scritto:
        > Ciao,
        > Ecco il rapporto.
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "Grazie mille!")
    }

    func testRemoveQuotes_portuguesePattern_escreveu_cleansCorrectly() {
        let text = """
        Obrigado!

        Em 15 de janeiro de 2024, João Silva escreveu:
        > Olá,
        > Aqui está o relatório.
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "Obrigado!")
    }

    func testRemoveQuotes_dutchPattern_schreef_cleansCorrectly() {
        let text = """
        Bedankt!

        Op 15 januari 2024 schreef Jan de Vries:
        > Hallo,
        > Hier is het rapport.
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "Bedankt!")
    }

    func testRemoveQuotes_germanForwardedMessage_cleansCorrectly() {
        let text = """
        Siehe unten.

        Weitergeleitete Nachricht:
        Von: Hans <hans@example.de>
        Betreff: Info

        Original content.
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "Siehe unten.")
    }

    func testRemoveQuotes_frenchForwardedMessage_cleansCorrectly() {
        let text = """
        Voir ci-dessous.

        Message transféré:
        De: Jean <jean@example.fr>
        Objet: Info

        Original content.
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertEqual(result, "Voir ci-dessous.")
    }

    // MARK: - Nested Quote Level Tests

    func testExtractQuotes_nestedQuotes_tracksNestingLevel() {
        let text = """
        My reply.

        On Jan 15, John wrote:
        > Original message
        >> Even older message
        >>> Very old message
        """
        let result = PlainTextQuoteRemover.extractQuotes(from: text)
        XCTAssertEqual(result.mainContent, "My reply.")
        XCTAssertEqual(result.quotedParts.count, 1)

        // The nested quote should have max nesting level of 3
        let quotedPart = result.quotedParts.first
        XCTAssertNotNil(quotedPart)
        XCTAssertEqual(quotedPart?.nestingLevel, 3)
    }

    func testExtractQuotes_singleLevelQuote_hasNestingLevelOne() {
        let text = """
        Thanks!

        On Jan 15, John wrote:
        > Just one level
        > of quoting here
        """
        let result = PlainTextQuoteRemover.extractQuotes(from: text)
        XCTAssertEqual(result.mainContent, "Thanks!")
        XCTAssertEqual(result.quotedParts.count, 1)
        XCTAssertEqual(result.quotedParts.first?.nestingLevel, 1)
    }

    func testExtractQuotes_mixedNestingLevels_tracksMaxLevel() {
        let text = """
        Got it.

        On Jan 15, John wrote:
        > First level
        >> Second level
        > Back to first
        >> Second again
        >>> Third level!
        > First level
        """
        let result = PlainTextQuoteRemover.extractQuotes(from: text)
        XCTAssertEqual(result.mainContent, "Got it.")

        // Max nesting level encountered should be 3
        let quotedPart = result.quotedParts.first
        XCTAssertEqual(quotedPart?.nestingLevel, 3)
    }

    func testExtractQuotes_noQuoteMarkers_hasNestingLevelZero() {
        let text = """
        My response.

        On Jan 15, John wrote:
        Original message without quote markers
        Just plain text in the quote section
        """
        let result = PlainTextQuoteRemover.extractQuotes(from: text)
        XCTAssertEqual(result.mainContent, "My response.")

        // No ">" markers means nesting level 0
        let quotedPart = result.quotedParts.first
        XCTAssertEqual(quotedPart?.nestingLevel, 0)
    }

    // MARK: - Signature Removal - CID Image References

    func testRemoveSignature_cidWithNameTitleBlock_removesEntireSignature() {
        let text = """
        Thank you so much. We truly appreciate your flexibility!

        Lauren Vien
        Director of Admissions and Community Engagement,
        Nursery School

        [cid:bfa5a8c2-a3e9-4924-9df3-d3fd51d2c906]

        New York's global center for culture,
        connection and enrichment
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, "Thank you so much. We truly appreciate your flexibility!")
    }

    func testRemoveSignature_cidAlone_removes() {
        let text = """
        Thanks for your help!

        [cid:abc123]
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, "Thanks for your help!")
    }

    func testRemoveSignature_cidWithOnlyNameBefore_removesNameAndCid() {
        let text = """
        Looking forward to it.

        John Doe

        [cid:logo123]
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, "Looking forward to it.")
    }

    func testRemoveSignature_cidWithMultipleShortLinesBeforeBlank_removesAll() {
        let text = """
        See you tomorrow!

        Jane Smith
        Senior Vice President
        Acme Corporation
        New York, NY

        [cid:company-logo]
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, "See you tomorrow!")
    }

    func testRemoveSignature_cidAfterContentSentence_preservesContent() {
        // If the line before CID ends with sentence punctuation, it's likely content
        let text = """
        Here is the document you requested.

        [cid:attachment123]
        """
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        // The line ends with period, so backward search stops there
        XCTAssertEqual(result, "Here is the document you requested.")
    }

    func testRemoveSignature_cidInlineNotRemoved() {
        // CID references that are inline (not at start of line) should not trigger removal
        // Our pattern requires "\n[cid:" so inline CIDs are not matched
        let text = "Check out this image: [cid:inline-image] in my message."
        let result = PlainTextQuoteRemover.removeSignature(from: text)
        XCTAssertEqual(result, text)
    }

    // MARK: - Mid-sentence "on the" preservation

    func testRemoveQuotes_onTheInMiddleOfSentence_preservesContent() {
        // Bug fix: "on the" in middle of sentence should NOT trigger "On ... wrote:" pattern
        // This was causing "I need to reload on the Chablis" to be truncated
        let text = """
        Hey!

        I need to reload on the Chablis. When can you deliver?

        Thanks!

        On Jan 31, 2026 at 12:31 PM, Scott Wunderlich wrote:
        > Hey Kevin,
        > Just checking in about the order.
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertTrue(result?.contains("on the Chablis") ?? false, "Should preserve 'on the Chablis'")
        XCTAssertTrue(result?.contains("When can you deliver") ?? false, "Should preserve 'When can you deliver'")
        XCTAssertTrue(result?.contains("Thanks!") ?? false, "Should preserve 'Thanks!'")
        XCTAssertFalse(result?.contains("Hey Kevin") ?? true, "Should remove quoted content")
    }

    func testRemoveQuotes_onInMiddleOfSentence_preservesContent() {
        // Various sentences with "on" mid-sentence should be preserved
        let text = """
        I'm working on the project now.

        The meeting is on Thursday at 3pm.

        On Monday, John wrote:
        > Previous message
        """
        let result = PlainTextQuoteRemover.removeQuotes(from: text)
        XCTAssertTrue(result?.contains("working on the project") ?? false)
        XCTAssertTrue(result?.contains("meeting is on Thursday") ?? false)
        XCTAssertFalse(result?.contains("Previous message") ?? true)
    }

    // MARK: - Attribution Without Date Prefix

    func testExtractQuotes_attributionWithoutDatePrefix_filtersCorrectly() {
        // Bug fix: "John wrote:" without a date prefix like "On Jan 15" should still be filtered
        let text = """
        Thanks for the update!

        John Smith wrote:
        > Here is the original message
        > with some content
        """
        let result = PlainTextQuoteRemover.extractQuotes(from: text)
        XCTAssertEqual(result.mainContent, "Thanks for the update!")
        XCTAssertEqual(result.quotedParts.count, 1)

        // The quoted part should not contain "John Smith wrote:" attribution line
        let quotedContent = result.quotedParts.first?.text ?? ""
        XCTAssertFalse(quotedContent.lowercased().contains("wrote:"))
        XCTAssertTrue(quotedContent.contains("Here is the original message"))
    }

    func testExtractQuotes_germanAttributionWithoutDatePrefix_filtersCorrectly() {
        let text = """
        Danke!

        Hans Müller schrieb:
        > Original nachricht
        > Zweite zeile
        """
        let result = PlainTextQuoteRemover.extractQuotes(from: text)
        XCTAssertEqual(result.mainContent, "Danke!")

        let quotedContent = result.quotedParts.first?.text ?? ""
        XCTAssertFalse(quotedContent.lowercased().contains("schrieb:"))
    }
}
