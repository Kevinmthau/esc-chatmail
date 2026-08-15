import XCTest
@testable import esc_chatmail

/// Tests for the DOM-based quote remover. These intentionally cover the
/// provider-specific structures that `HTMLQuoteRemover` delegates here.
///
/// Unlike `HTMLQuoteRemoverTests`, these tests don't compare HTML strings
/// directly (SwiftSoup re-emits HTML with normalized attribute order, which
/// would make exact-match comparisons flaky). They check semantic outcomes:
/// is the response visible? Is the quoted content gone?
final class EmailDOMQuoteRemoverTests: XCTestCase {

    // MARK: - Helpers

    private func plainText(_ html: String?) -> String {
        guard let html else { return "" }
        return EmailDocument.tryParse(html)?.plainText(preserveParagraphs: true) ?? ""
    }

    // MARK: - Nil / empty

    func testRemoveQuotes_nilInput_returnsNil() {
        XCTAssertNil(EmailDOMQuoteRemover.removeQuotes(from: nil))
    }

    func testRemoveQuotes_emptyString_returnsString() {
        let result = EmailDOMQuoteRemover.removeQuotes(from: "")
        XCTAssertNotNil(result)
    }

    // MARK: - Gmail patterns

    func testRemoveQuotes_gmailQuote_dropsQuotedContent() {
        let html = """
        <p>My response here.</p>
        <div class="gmail_quote"><p>Original quoted content</p></div>
        """
        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))
        XCTAssertTrue(text.contains("My response here."))
        XCTAssertFalse(text.contains("Original quoted content"))
    }

    func testRemoveQuotes_gmailQuote_withMultipleClasses() {
        let html = """
        <p>Visible body.</p>
        <div class="gmail_quote gmail_quote_container"><p>Quoted</p></div>
        """
        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))
        XCTAssertTrue(text.contains("Visible body."))
        XCTAssertFalse(text.contains("Quoted"))
    }

    func testRemoveQuotes_gmailAttr_dropsAttribution() {
        let html = """
        <p>Reply.</p>
        <div class="gmail_attr">On Mon, Jan 15, 2024 at 10:30 AM John wrote:</div>
        <div class="gmail_quote"><p>Quoted content</p></div>
        """
        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))
        XCTAssertTrue(text.contains("Reply."))
        XCTAssertFalse(text.contains("John wrote"))
        XCTAssertFalse(text.contains("Quoted content"))
    }

    // MARK: - Apple Mail

    func testRemoveQuotes_appleMailBlockquote_dropsCite() {
        let html = """
        <p>Reply.</p>
        <blockquote type="cite"><p>Earlier message</p></blockquote>
        """
        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))
        XCTAssertTrue(text.contains("Reply."))
        XCTAssertFalse(text.contains("Earlier message"))
    }

    // MARK: - Outlook structural boundary

    func testRemoveQuotes_outlookReferenceContainer_truncates() {
        let html = """
        <p>Visible.</p>
        <div id="mail-editor-reference-message-container"><p>Quote</p></div>
        <p>Stale tail content</p>
        """
        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))
        XCTAssertTrue(text.contains("Visible."))
        XCTAssertFalse(text.contains("Quote"))
        XCTAssertFalse(text.contains("Stale tail content"),
                       "Truncation at structural boundary should remove content after the boundary too.")
    }

    func testRemoveQuotes_outlookReferenceContainer_prefixedId_truncates() {
        // Outlook for the web prefixes IDs with `x_`.
        let html = """
        <p>Visible.</p>
        <div id="x_mail-editor-reference-message-container"><p>Quote</p></div>
        """
        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))
        XCTAssertTrue(text.contains("Visible."))
        XCTAssertFalse(text.contains("Quote"))
    }

    func testRemoveQuotes_strongFromSubjectHeaderWithoutReferenceContainer_truncates() {
        let html = """
        <div>Current reply.</div>
        <div><strong>From:</strong> Alice Example</div>
        <div><strong>Sent:</strong> Monday, January 1, 2026 9:00 AM</div>
        <div><strong>To:</strong> Bob Example</div>
        <div><strong>Subject:</strong> Re: Planning</div>
        <div>Older thread should be hidden.</div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))

        XCTAssertTrue(text.contains("Current reply."))
        XCTAssertFalse(text.contains("Alice Example"))
        XCTAssertFalse(text.contains("Older thread should be hidden."))
    }

    func testRemoveQuotes_tableHeaderBlockAfterQuoteMarker_truncates() {
        let html = """
        <div>Current reply.</div>
        <div>-----Original Message-----</div>
        <table>
            <tr><td>From:</td><td>Alice Example &lt;alice@example.com&gt;</td></tr>
            <tr><td>Sent:</td><td>Monday, January 1, 2026 9:00 AM</td></tr>
            <tr><td>To:</td><td>Bob Example</td></tr>
            <tr><td>Subject:</td><td>Re: Planning</td></tr>
        </table>
        <div>Older thread should be hidden.</div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))

        XCTAssertEqual(text, "Current reply.")
        XCTAssertFalse(text.contains("Alice Example"))
        XCTAssertFalse(text.contains("Older thread should be hidden."))
    }

    func testRemoveQuotes_tableHeaderBlockAfterBlankSeparatorWithoutQuoteSignal_preservesContent() {
        let html = """
        <div>Please review this request.</div>
        <div><br></div>
        <table>
            <tr><td>From:</td><td>Alice Example &lt;alice@example.com&gt;</td></tr>
            <tr><td>To:</td><td>Support</td></tr>
            <tr><td>Date:</td><td>Monday, January 1, 2026 9:00 AM</td></tr>
            <tr><td>Subject:</td><td>Contact request</td></tr>
        </table>
        <div>Please follow up this week.</div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))

        XCTAssertTrue(text.contains("Please review this request."))
        XCTAssertTrue(text.contains("From: Alice Example"))
        XCTAssertTrue(text.contains("alice@example.com"))
        XCTAssertTrue(text.contains("To: Support"))
        XCTAssertTrue(text.contains("Date: Monday, January 1, 2026 9:00 AM"))
        XCTAssertTrue(text.contains("Subject: Contact request"))
        XCTAssertTrue(text.contains("Please follow up this week."))
    }

    func testRemoveQuotes_earlierTableHeaderWithQuoteMarkerBeforeLaterNestedTableHeader_truncatesAtEarlierTable() {
        let html = """
        <html>
        <body>
        <div>Current reply.</div>
        <div>-----Original Message-----</div>
        <div><br></div>
        <table>
            <tr><td>From:</td><td>Alice Example &lt;alice@example.com&gt;</td></tr>
            <tr><td>Sent:</td><td>Monday, January 1, 2026 9:00 AM</td></tr>
            <tr><td>To:</td><td>Bob Example &lt;bob@example.com&gt;</td></tr>
            <tr><td>Subject:</td><td>Re: Planning</td></tr>
        </table>
        <div>First quoted block should be hidden.</div>
        <div><br></div>
        <table>
            <tr>
                <td>
                    <table>
                        <tr><td>From:</td><td>Carol Example &lt;carol@example.com&gt;</td></tr>
                        <tr><td>Sent:</td><td>Sunday, December 31, 2025 4:00 PM</td></tr>
                        <tr><td>To:</td><td>Alice Example &lt;alice@example.com&gt;</td></tr>
                        <tr><td>Subject:</td><td>Fwd: Planning</td></tr>
                    </table>
                </td>
            </tr>
        </table>
        <div>Nested quoted block should also be hidden.</div>
        </body>
        </html>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))

        XCTAssertEqual(text, "Current reply.")
        XCTAssertFalse(text.contains("Alice Example"))
        XCTAssertFalse(text.contains("First quoted block should be hidden."))
        XCTAssertFalse(text.contains("Carol Example"))
        XCTAssertFalse(text.contains("Nested quoted block should also be hidden."))
    }

    func testRemoveQuotes_nestedTableHeaderBlockAfterSignaturePreservesOuterReplyContent() {
        let html = """
        <html>
        <body>
        <table>
            <tr>
                <td>
                    <div>Current reply.</div>
                    <div>Jane Example</div>
                    <div>jane@example.com</div>
                    <table>
                        <tr><td>From:</td><td>Alice Example &lt;alice@example.com&gt;</td></tr>
                        <tr><td>Sent:</td><td>Monday, January 1, 2026 9:00 AM</td></tr>
                        <tr><td>To:</td><td>Bob Example &lt;bob@example.com&gt;</td></tr>
                        <tr><td>Subject:</td><td>Re: Planning</td></tr>
                    </table>
                </td>
            </tr>
            <tr><td>Older thread should be hidden.</td></tr>
        </table>
        </body>
        </html>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))

        XCTAssertTrue(text.contains("Current reply."))
        XCTAssertFalse(text.contains("Alice Example"))
        XCTAssertFalse(text.contains("Older thread should be hidden."))
    }

    func testRemoveQuotes_tableHeaderAfterTelephoneSignature_truncates() {
        let html = """
        <div>Current reply.</div>
        <div>Telephone: 415-555-1212</div>
        <table>
            <tr><td>From:</td><td>Alice Example &lt;alice@example.com&gt;</td></tr>
            <tr><td>Sent:</td><td>Monday, January 1, 2026 9:00 AM</td></tr>
            <tr><td>To:</td><td>Bob Example</td></tr>
            <tr><td>Subject:</td><td>Re: Planning</td></tr>
        </table>
        <div>Older thread should be hidden.</div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))

        XCTAssertEqual(text, "Current reply.\n\nTelephone: 415-555-1212")
        XCTAssertFalse(text.contains("Alice Example"))
        XCTAssertFalse(text.contains("Older thread should be hidden."))
    }

    func testRemoveQuotes_tableFieldStyleContentWithoutQuoteMarker_preservesContent() {
        let html = """
        <div>Trip details</div>
        <table>
            <tr><td>From:</td><td>SFO</td></tr>
            <tr><td>To:</td><td>JFK</td></tr>
            <tr><td>Date:</td><td>Jun 1</td></tr>
        </table>
        <div>Window seat preferred.</div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))

        XCTAssertTrue(text.contains("Trip details"))
        XCTAssertTrue(text.contains("From: SFO"))
        XCTAssertTrue(text.contains("To: JFK"))
        XCTAssertTrue(text.contains("Date: Jun 1"))
        XCTAssertTrue(text.contains("Window seat preferred."))
    }

    func testRemoveQuotes_midBodyFieldStyleLines_preservesContent() {
        let html = """
        <div>Trip details</div>
        <div><br></div>
        <div>From: SFO</div>
        <div>To: JFK</div>
        <div>Date: Jun 1</div>
        <div>Window seat preferred.</div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))

        XCTAssertTrue(text.contains("Trip details"))
        XCTAssertTrue(text.contains("From: SFO"))
        XCTAssertTrue(text.contains("To: JFK"))
        XCTAssertTrue(text.contains("Date: Jun 1"))
        XCTAssertTrue(text.contains("Window seat preferred."))
    }

    func testRemoveQuotes_startOfBodyFieldStyleLines_preservesContent() {
        let html = """
        <div>From: SFO</div>
        <div>To: JFK</div>
        <div>Date: Jun 1</div>
        <div>Window seat preferred.</div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))

        XCTAssertTrue(text.contains("From: SFO"))
        XCTAssertTrue(text.contains("To: JFK"))
        XCTAssertTrue(text.contains("Date: Jun 1"))
        XCTAssertTrue(text.contains("Window seat preferred."))
    }

    func testRemoveQuotes_brSeparatedHeaderBlock_truncates() {
        let html = """
        <div>Current reply.</div>
        <div>
            From: Alice Example &lt;alice@example.com&gt;<br>
            Sent: Monday, January 1, 2026 9:00 AM<br>
            To: Bob Example &lt;bob@example.com&gt;<br>
            Subject: Re: Planning<br><br>
            Older thread should be hidden.
        </div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))

        XCTAssertEqual(text, "Current reply.")
        XCTAssertFalse(text.contains("Alice Example"))
        XCTAssertFalse(text.contains("Older thread should be hidden."))
    }

    func testRemoveQuotes_brSeparatedHeaderBlockAsFirstVisibleContent_preservesContent() {
        let html = """
        <div>
            From: Alice Example &lt;alice@example.com&gt;<br>
            Sent: Monday, January 1, 2026 9:00 AM<br>
            To: Support &lt;support@example.com&gt;<br>
            Subject: Contact request<br><br>
            Please call me back.
        </div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))

        XCTAssertTrue(text.contains("From: Alice Example"))
        XCTAssertTrue(text.contains("alice@example.com"))
        XCTAssertTrue(text.contains("Subject: Contact request"))
        XCTAssertTrue(text.contains("Please call me back."))
    }

    func testRemoveQuotes_brSeparatedHeaderBlockAfterHiddenPreheaderAsFirstVisibleContent_preservesContent() {
        let html = """
        <div style="display:none; max-height:0; overflow:hidden;">Preview text before the visible message.</div>
        <div>
            From: Alice Example &lt;alice@example.com&gt;<br>
            Sent: Monday, January 1, 2026 9:00 AM<br>
            To: Support &lt;support@example.com&gt;<br>
            Subject: Contact request<br><br>
            Please call me back.
        </div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))

        XCTAssertTrue(text.contains("From: Alice Example"))
        XCTAssertTrue(text.contains("alice@example.com"))
        XCTAssertTrue(text.contains("Subject: Contact request"))
        XCTAssertTrue(text.contains("Please call me back."))
    }

    func testRemoveQuotes_brSeparatedFieldStyleContentWithoutEmailMetadata_preservesContent() {
        let html = """
        <div>Trip details</div>
        <div>
            From: SFO<br>
            To: JFK<br>
            Date: Jun 1<br>
            Subject: Seat request<br><br>
            Window seat preferred.
        </div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))

        XCTAssertTrue(text.contains("Trip details"))
        XCTAssertTrue(text.contains("From: SFO"))
        XCTAssertTrue(text.contains("To: JFK"))
        XCTAssertTrue(text.contains("Date: Jun 1"))
        XCTAssertTrue(text.contains("Subject: Seat request"))
        XCTAssertTrue(text.contains("Window seat preferred."))
    }

    func testRemoveQuotes_signatureMode_removesGenericContactSignatureBeforeHeader() {
        let html = """
        <div>Hi Kevin,</div>
        <div>The estimate changed.</div>
        <div>Buchalter</div>
        <div>Monica</div>
        <div>Mazzei</div>
        <div>Partner | Certified Family Law Specialist</div>
        <div>T</div>
        <div><br></div>
        <div>monica@examplelaw.com</div>
        <div>425 Market Street, Suite 2900</div>
        <div>San Francisco, CA 94105</div>
        <div>www.examplelaw.com</div>
        <div>From: Kevin Thau &lt;kmthau@gmail.com&gt;</div>
        <div>Sent: Thursday, February 12, 2026 12:45 PM</div>
        <div>To: Monica Example &lt;monica@examplelaw.com&gt;</div>
        <div>Subject: Re: Draft Settlement Letter</div>
        <div>Thanks for sending this over.</div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html, mode: .quotedAndSignatures))

        XCTAssertEqual(text, "Hi Kevin,\n\nThe estimate changed.")
        XCTAssertFalse(text.contains("Buchalter"))
        XCTAssertFalse(text.contains("From: Kevin Thau"))
    }

    func testRemoveQuotes_signatureMode_preservesPhoneSentenceBeforeCorporateSignatureAndOutlookQuote() {
        let html = """
        <p>Hi Recipient,</p>
        <p>&nbsp;</p>
        <p>Can you give me a call? 415-555-0101</p>
        <p>&nbsp;</p>
        <table>
          <tbody>
            <tr><td>Example Firm</td></tr>
            <tr><td>Alex Example</td></tr>
            <tr><td>Partner</td></tr>
            <tr><td>T (415) 555-0100</td></tr>
            <tr><td>alex@example.test</td></tr>
          </tbody>
        </table>
        <div style="border-top: solid #E1E1E1 1pt">
          <p>
            <b>From:</b> Sender Example &lt;sender@example.test&gt;<br>
            <b>Sent:</b> Friday, August 14, 2026 11:37 AM<br>
            <b>To:</b> Recipient Example &lt;recipient@example.test&gt;<br>
            <b>Subject:</b> Re: Example
          </p>
        </div>
        <p>Older quoted content.</p>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html, mode: .quotedAndSignatures))

        XCTAssertEqual(text, "Hi Recipient,\n\nCan you give me a call? 415-555-0101")
        XCTAssertFalse(text.contains("Example Firm"))
        XCTAssertFalse(text.contains("Older quoted content."))
    }

    func testRemoveQuotes_signatureMode_preservesReferenceBeforeContactSignature() {
        let referenceLines = [
            "P2026-0815",
            "Deadline: 2026-08-15",
            "Case: 2026-0815",
            "P-2026-0815",
            "Case: 1234-5678",
            "Invoice: 12345678",
            "Invoice | 12345678",
            "Invoice Number | 12345678",
            "Reference Number | 1234-5678",
            "Deadline: 08-15-2026",
            "8-15-2026",
            "2026-8-15"
        ]

        for referenceLine in referenceLines {
            let html = """
            <div>Current reply.</div>
            <div>\(referenceLine)</div>
            <div>John Smith</div>
            <div>Partner</div>
            <div>john@example.test</div>
            <div>415-555-1212</div>
            """

            let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html, mode: .quotedAndSignatures))

            XCTAssertEqual(text, "Current reply.\n\n\(referenceLine)")
            XCTAssertFalse(text.contains("John Smith"))
            XCTAssertFalse(text.contains("john@example.test"))
        }
    }

    func testRemoveQuotes_signatureMode_removesDelimitedPhoneExtensionSignatures() {
        let phoneLines = [
            "T 415-555-1212 | x112",
            "T 415-555-1212, ext. 112",
            "T 415-555-1212; x112",
            "T 415-555-1212 / F 650-555-1212",
            "T 415-555-1212 │ M 650-555-1212",
            "T: 415-555-1212 F: 650-555-1213",
            "Phone Number: 415-555-1212"
        ]

        for phoneLine in phoneLines {
            let html = """
            <div>Current reply.</div>
            <div>John Smith</div>
            <div>Partner</div>
            <div>john@example.test</div>
            <div>\(phoneLine)</div>
            """

            let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html, mode: .quotedAndSignatures))

            XCTAssertEqual(text, "Current reply.", "Expected signature removal for: \(phoneLine)")
            XCTAssertFalse(text.contains("John Smith"), "Expected signature removal for: \(phoneLine)")
            XCTAssertFalse(text.contains("415-555-1212"), "Expected signature removal for: \(phoneLine)")
        }
    }

    func testIsContactSignatureLine_phoneFormatsDistinguishesStandaloneLinesFromProse() {
        let signatureLines = [
            "415-555-1212",
            "(415) 555-1212",
            "+1 415 555 1212",
            "415-555-1212 x112",
            "415-555-1212x112",
            "415-555-1212 extension 112",
            "415-555-1212, ext. 112",
            "415-555-1212; x112",
            "415-555-1212 (mobile)",
            "T (415) 227-3629",
            "T | 415-555-1212",
            "John Smith | Phone | 4155551212",
            "T 415-555-1212 | x112",
            "415-555-1212 | ext. 112",
            "T 415-555-1212 | F 415-555-1213",
            "T 415-555-1212 x100 | M 650-555-1212",
            "415-555-1212 (office) | 650-555-1212 (mobile)",
            "T 415-555-1212 / F 650-555-1212",
            "T 415-555-1212 │ M 650-555-1212",
            "T: 415-555-1212 F: 650-555-1213",
            "Phone: 415-555-1212",
            "Phone Number: 415-555-1212",
            "Cell: 650-255-5222",
            "Telephone: 415-555-1212",
            "Telephone Number: 415-555-1212",
            "Téléphone: 415-555-1212",
            "Teléfono: 415-555-1212",
            "Home: 415-555-1212",
            "Work: 415-555-1212",
            "W: 415-555-1212",
            "Main: 415-555-1212",
            "John Smith | 415-555-1212"
        ]
        let proseLines = [
            "Can you give me a call? 415-283-6379",
            "Call me at (415) 555-1212 when you are free.",
            "My mobile is +1 415 555 1212; text me first.",
            "Phone: 415-555-1212 if anything comes up.",
            "P2026-0815",
            "Deadline: 2026-08-15",
            "Case: 2026-0815",
            "P-2026-0815",
            "Case: 1234-5678",
            "Invoice: 12345678",
            "Invoice | 12345678",
            "Invoice Number | 12345678",
            "Reference Number | 1234-5678",
            "Deadline: 08-15-2026",
            "8-15-2026",
            "2026-8-15",
            "P2 - 2026",
            "P: 1.2.3.4",
            "T: 12.30.00"
        ]

        for line in signatureLines {
            XCTAssertTrue(EmailDOMQuoteRemover.isContactSignatureLine(line), "Expected signature line: \(line)")
        }
        for line in proseLines {
            XCTAssertFalse(EmailDOMQuoteRemover.isContactSignatureLine(line), "Expected prose line: \(line)")
        }
    }

    func testRemoveQuotes_signatureMode_preservesBodyLineBeforeContactSignatureWithoutBlank() {
        let html = """
        <div>The estimate changed.</div>
        <div>John Doe</div>
        <div>Partner</div>
        <div>john@example.com</div>
        <div>415.555.1212</div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html, mode: .quotedAndSignatures))

        XCTAssertEqual(text, "The estimate changed.")
        XCTAssertFalse(text.contains("John Doe"))
        XCTAssertFalse(text.contains("john@example.com"))
    }

    func testRemoveQuotes_signatureMode_removesMinimalContactSignatureWithoutTitle() {
        let html = """
        <div>The estimate changed.</div>
        <div>John Doe</div>
        <div>john@example.com</div>
        <div>415-555-1212</div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html, mode: .quotedAndSignatures))

        XCTAssertEqual(text, "The estimate changed.")
        XCTAssertFalse(text.contains("John Doe"))
        XCTAssertFalse(text.contains("john@example.com"))
        XCTAssertFalse(text.contains("415-555-1212"))
    }

    func testRemoveQuotes_signatureMode_preservesTrailingContactListWithFinalBodyLine() {
        let html = """
        <div>Please pick one of these contacts.</div>
        <div>Jane</div>
        <div>jane@example.com</div>
        <div>John</div>
        <div>john@example.com</div>
        <div>Please pick one</div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html, mode: .quotedAndSignatures))

        XCTAssertTrue(text.contains("Please pick one of these contacts."))
        XCTAssertTrue(text.contains("Jane"))
        XCTAssertTrue(text.contains("jane@example.com"))
        XCTAssertTrue(text.contains("John"))
        XCTAssertTrue(text.contains("john@example.com"))
        XCTAssertTrue(text.contains("Please pick one"))
    }

    func testRemoveQuotes_signatureMode_preservesTrailingContactListEndingOnContactLine() {
        let html = """
        <div>Here are the contacts:</div>
        <div>Jane</div>
        <div>jane@example.com</div>
        <div>John</div>
        <div>john@example.com</div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html, mode: .quotedAndSignatures))

        XCTAssertTrue(text.contains("Here are the contacts:"))
        XCTAssertTrue(text.contains("Jane"))
        XCTAssertTrue(text.contains("jane@example.com"))
        XCTAssertTrue(text.contains("John"))
        XCTAssertTrue(text.contains("john@example.com"))
    }

    func testRemoveQuotes_signatureMode_preservesTrailingContactListAfterBlankSeparatorEndingOnContactLine() {
        let html = """
        <div>Here are the contacts:</div>
        <div><br></div>
        <div>Jane</div>
        <div>jane@example.com</div>
        <div>John</div>
        <div>john@example.com</div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html, mode: .quotedAndSignatures))

        XCTAssertTrue(text.contains("Here are the contacts:"))
        XCTAssertTrue(text.contains("Jane"))
        XCTAssertTrue(text.contains("jane@example.com"))
        XCTAssertTrue(text.contains("John"))
        XCTAssertTrue(text.contains("john@example.com"))
    }

    func testRemoveQuotes_signatureMode_preservesReviewerEmailListEndingOnContactLine() {
        let html = """
        <div>Please email both reviewers:</div>
        <div>Alice Smith</div>
        <div>alice@example.com</div>
        <div>Bob Jones</div>
        <div>bob@example.com</div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html, mode: .quotedAndSignatures))

        XCTAssertTrue(text.contains("Please email both reviewers:"))
        XCTAssertTrue(text.contains("Alice Smith"))
        XCTAssertTrue(text.contains("alice@example.com"))
        XCTAssertTrue(text.contains("Bob Jones"))
        XCTAssertTrue(text.contains("bob@example.com"))
    }

    func testRemoveQuotes_signatureMode_preservesTrailingContactListWithNonKeywordIntro() {
        let html = """
        <div>Can you loop in these people?</div>
        <div>Alice Smith</div>
        <div>alice@example.com</div>
        <div>Bob Jones</div>
        <div>bob@example.com</div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html, mode: .quotedAndSignatures))

        XCTAssertTrue(text.contains("Can you loop in these people?"))
        XCTAssertTrue(text.contains("Alice Smith"))
        XCTAssertTrue(text.contains("alice@example.com"))
        XCTAssertTrue(text.contains("Bob Jones"))
        XCTAssertTrue(text.contains("bob@example.com"))
    }

    // MARK: - Text marker ("On ... wrote:")

    func testRemoveQuotes_onDateWrote_truncatesAtMarker() {
        let html = """
        <div>My reply.</div>
        <div>On Mon, Jan 15, 2024 at 10:30 AM John wrote:</div>
        <blockquote>Earlier message</blockquote>
        """
        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))
        XCTAssertTrue(text.contains("My reply."))
        XCTAssertFalse(text.contains("John wrote"))
        XCTAssertFalse(text.contains("Earlier message"))
    }

    func testRemoveQuotes_onDateWroteAfterLineBreakInsideTextNode_removesFollowingNodes() {
        let html = """
        <p>Hello.
        On Mon, Jan 15, 2024 at 10:30 AM John wrote:<span>inline quote</span></p>
        <p>Older message</p>
        """
        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))
        XCTAssertTrue(text.contains("Hello."))
        XCTAssertFalse(text.contains("John wrote"))
        XCTAssertFalse(text.contains("inline quote"))
        XCTAssertFalse(text.contains("Older message"))
    }

    func testRemoveQuotes_inlineSplitOnDateWrote_truncatesAtMarker() {
        let html = """
        <div>Current reply.</div>
        <div>On Jan 1 <b>John</b> wrote:</div>
        <div>Old thread should be hidden.</div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))

        XCTAssertTrue(text.contains("Current reply."))
        XCTAssertFalse(text.contains("John"))
        XCTAssertFalse(text.contains("Old thread should be hidden."))
    }

    func testRemoveQuotes_inlineSplitOnDateWroteAfterBR_truncatesAtMarker() {
        let html = """
        <div>Current reply.<br>On Jan 1 <b>John</b> wrote:</div>
        <div>Old thread should be hidden.</div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))

        XCTAssertTrue(text.contains("Current reply."))
        XCTAssertFalse(text.contains("John"))
        XCTAssertFalse(text.contains("Old thread should be hidden."))
    }

    func testRemoveQuotes_midSentenceOnWrote_preservesCurrentContent() {
        let html = """
        <p>Following up on what John wrote: I agree with the plan.</p>
        <p>Current message should remain visible.</p>
        <p>On Mon, Jan 15, 2024 at 10:30 AM John wrote:</p>
        <p>Older message</p>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))

        XCTAssertTrue(text.contains("Following up on what John wrote: I agree with the plan."))
        XCTAssertTrue(text.contains("Current message should remain visible."))
        XCTAssertFalse(text.contains("Older message"))
    }

    func testRemoveQuotes_inlineSplitMarkerBeforeSingleNodeMarker_truncatesAtEarlierSplitMarker() {
        let html = """
        <div>Current reply.</div>
        <div>On Jan 1 <b>John</b> wrote:</div>
        <div>Nested reply should be hidden.</div>
        <div>On Dec 31 Jane wrote:</div>
        <div>Older thread should also be hidden.</div>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))

        XCTAssertTrue(text.contains("Current reply."))
        XCTAssertFalse(text.contains("On Jan 1"))
        XCTAssertFalse(text.contains("John"))
        XCTAssertFalse(text.contains("Nested reply should be hidden."))
        XCTAssertFalse(text.contains("Jane"))
        XCTAssertFalse(text.contains("Older thread should also be hidden."))
    }

    func testRemoveQuotes_inlineSplitOnDateWrote_preservesPrefixBeforeMarker() {
        let html = """
        <p>Hello.
        On Jan 1 <b>John</b> wrote:<span>inline quote</span></p>
        <p>Older message</p>
        """

        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html))

        XCTAssertEqual(text, "Hello.")
        XCTAssertFalse(text.contains("John"))
        XCTAssertFalse(text.contains("inline quote"))
        XCTAssertFalse(text.contains("Older message"))
    }

    // MARK: - Signature mode

    func testRemoveQuotes_signatureMode_removesGmailSignature() {
        let html = """
        <p>Body.</p>
        <div class="gmail_signature">--<br>Sent from my iPhone</div>
        """
        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html, mode: .quotedAndSignatures))
        XCTAssertTrue(text.contains("Body."))
        XCTAssertFalse(text.contains("Sent from my iPhone"))
    }

    func testRemoveQuotes_signatureMode_preservesCombinedMultiWordSignOffAndName() {
        let html = """
        <p>Body.</p>
        <div class="gmail_signature">
            <div>Best regards John Ronald Reuel Tolkien</div>
            <div>Professor of Anglo-Saxon</div>
            <div>tolkien@example.com</div>
        </div>
        """
        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html, mode: .quotedAndSignatures))
        XCTAssertTrue(text.contains("Body."))
        XCTAssertTrue(text.contains("Best regards John Ronald Reuel Tolkien"))
        XCTAssertFalse(text.contains("Professor of Anglo-Saxon"))
        XCTAssertFalse(text.contains("tolkien@example.com"))
    }

    func testRemoveQuotes_signatureMode_preservesSignOffNameLineBreakAndTail() {
        let html = """
        <div>Body.</div>
        <div class="gmail_signature">
            <div>
                <div>Best,<br>Janet</div>
                <div><table><tr><td>617.221.4242</td></tr></table></div>
            </div>
        </div>
        <div>P.S. one more thing.</div>
        """
        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html, mode: .quotedAndSignatures))
        XCTAssertEqual(text, "Body.\n\nBest,\nJanet\n\nP.S. one more thing.")
        XCTAssertFalse(text.contains("617.221.4242"))
    }

    func testRemoveQuotes_quotedOnly_keepsSignature() {
        // In .quotedOnly mode the signature should remain, so callers using
        // the lighter mode can still see compose-time signatures.
        let html = """
        <p>Body.</p>
        <div class="gmail_signature">--<br>Sent from my iPhone</div>
        """
        let text = plainText(EmailDOMQuoteRemover.removeQuotes(from: html, mode: .quotedOnly))
        XCTAssertTrue(text.contains("Body."))
        XCTAssertTrue(text.contains("Sent from my iPhone"))
    }

    // MARK: - Fragment vs document preservation

    func testRemoveQuotes_fragmentInput_returnsFragmentNotWrappedDocument() {
        // Reply quoting in MimeBuilder+Reply passes a fragment and expects a
        // fragment back. Wrapping a fragment with `<html><body>` would
        // corrupt outgoing MIME parts.
        let html = "<p>Body.</p><div class=\"gmail_quote\"><p>Quote</p></div>"
        let result = EmailDOMQuoteRemover.removeQuotes(from: html) ?? ""
        XCTAssertFalse(result.lowercased().contains("<html"),
                       "Fragment input should not gain <html> wrapper, got: \(result)")
        XCTAssertFalse(result.lowercased().contains("<body"),
                       "Fragment input should not gain <body> wrapper, got: \(result)")
    }

    func testRemoveQuotes_fragmentWithHeaderElement_returnsFragmentNotWrappedDocument() {
        let html = """
        <header><p>Body.</p></header>
        <div class="gmail_quote"><p>Quote</p></div>
        """

        let result = EmailDOMQuoteRemover.removeQuotes(from: html) ?? ""

        XCTAssertFalse(result.lowercased().contains("<html"),
                       "Fragment input should not gain <html> wrapper, got: \(result)")
        XCTAssertFalse(result.lowercased().contains("<body"),
                       "Fragment input should not gain <body> wrapper, got: \(result)")
        XCTAssertTrue(result.contains("<header>"))
        XCTAssertTrue(result.contains("<p>Body.</p>"))
        XCTAssertFalse(result.contains("Quote"))
    }

    func testRemoveQuotes_standaloneTableRowFragmentPreservesLayout() {
        let html = "<tr><td>Visible body.</td></tr>"

        let result = EmailDOMQuoteRemover.removeQuotes(from: html) ?? ""
        let lowercasedResult = result.lowercased()

        XCTAssertFalse(lowercasedResult.contains("<html"),
                       "Fragment input should not gain <html> wrapper, got: \(result)")
        XCTAssertFalse(lowercasedResult.contains("<body"),
                       "Fragment input should not gain <body> wrapper, got: \(result)")
        XCTAssertTrue(lowercasedResult.contains("<tr"))
        XCTAssertTrue(result.contains("<td>Visible body.</td>"))
    }

    func testRemoveQuotes_documentInput_returnsFullDocument() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>Test</title></head>
        <body><p>Body.</p><div class="gmail_quote"><p>Quote</p></div></body>
        </html>
        """
        let result = EmailDOMQuoteRemover.removeQuotes(from: html) ?? ""
        XCTAssertTrue(result.lowercased().contains("<html"),
                      "Document input should keep <html> wrapper, got: \(result)")
    }

    func testRemoveQuotes_lateBodyDocumentPreservesBodyAttributes() throws {
        let preheader = String(repeating: "Hidden preheader text. ", count: 120)
        let html = #"""
        <!-- \#(preheader) -->
        <body class="promo" style="margin:0" bgcolor="#f4f4f4">
          <p>Body.</p>
          <div class="gmail_quote"><p>Quote</p></div>
        </body>
        """#
        let bodyRange = try XCTUnwrap(html.range(of: "<body"))
        XCTAssertGreaterThan(html.distance(from: html.startIndex, to: bodyRange.lowerBound), 2048)

        let result = EmailDOMQuoteRemover.removeQuotes(from: html) ?? ""
        let lowercasedResult = result.lowercased()

        XCTAssertTrue(lowercasedResult.contains("<body"))
        XCTAssertTrue(result.contains(#"class="promo""#))
        XCTAssertTrue(result.contains(#"style="margin:0""#))
        XCTAssertTrue(result.contains("bgcolor=\"#f4f4f4\""))
        XCTAssertTrue(result.contains("<p>Body.</p>"))
        XCTAssertFalse(result.contains("Quote"))
    }

    // MARK: - Idempotence

    func testRemoveQuotes_isIdempotent() {
        let html = """
        <p>Visible.</p>
        <div class="gmail_quote"><p>Quoted</p></div>
        """
        let pass1 = EmailDOMQuoteRemover.removeQuotes(from: html)
        let pass2 = EmailDOMQuoteRemover.removeQuotes(from: pass1)
        XCTAssertEqual(plainText(pass1), plainText(pass2))
    }
}
