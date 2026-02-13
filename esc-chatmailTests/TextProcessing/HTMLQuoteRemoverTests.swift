import XCTest
@testable import esc_chatmail

final class HTMLQuoteRemoverTests: XCTestCase {

    // MARK: - Basic Functionality

    func testRemoveQuotes_nilInput_returnsNil() {
        let result = HTMLQuoteRemover.removeQuotes(from: nil)
        XCTAssertNil(result)
    }

    func testRemoveQuotes_emptyString_returnsEmptyString() {
        let result = HTMLQuoteRemover.removeQuotes(from: "")
        XCTAssertEqual(result, "")
    }

    func testRemoveQuotes_noQuotes_returnsOriginal() {
        let html = "<p>Hello, this is a simple message without any quotes.</p>"
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertEqual(result, html)
    }

    // MARK: - Gmail Quote Patterns

    func testRemoveQuotes_gmailExactClass_removesQuote() {
        let html = """
        <p>My response here.</p>
        <div class="gmail_quote">
            <p>Original quoted content</p>
        </div>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("My response here.") ?? false)
        XCTAssertFalse(result?.contains("Original quoted content") ?? true)
        XCTAssertFalse(result?.contains("gmail_quote") ?? true)
    }

    func testRemoveQuotes_gmailMultipleClasses_removesQuote() {
        // This tests the fix for Brynn Putnam's email being cut off
        // Gmail uses class="gmail_quote gmail_quote_container" for some quotes
        let html = """
        <p>Thank you for indulging us with the option to review.</p>
        <p>It turns out the art that we have doesn't work.</p>
        <div class="gmail_quote gmail_quote_container">
            <p>Previous email content here</p>
        </div>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("Thank you for indulging us") ?? false)
        XCTAssertTrue(result?.contains("It turns out the art") ?? false)
        XCTAssertFalse(result?.contains("Previous email content") ?? true)
    }

    func testRemoveQuotes_gmailQuoteContainerFirst_removesQuote() {
        // Test with gmail_quote_container appearing first
        let html = """
        <p>Main content.</p>
        <div class="gmail_quote_container gmail_quote">
            <p>Quoted text</p>
        </div>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("Main content.") ?? false)
        XCTAssertFalse(result?.contains("Quoted text") ?? true)
    }

    func testRemoveQuotes_gmailQuoteWithAttributes_removesQuote() {
        // Test with additional attributes on the div
        let html = """
        <p>Response text.</p>
        <div dir="ltr" class="gmail_quote" style="padding:0">
            <p>Original message</p>
        </div>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("Response text.") ?? false)
        XCTAssertFalse(result?.contains("Original message") ?? true)
    }

    func testRemoveQuotes_gmailAttr_removesAttribution() {
        // Gmail attribution container
        let html = """
        <p>My reply.</p>
        <div class="gmail_attr">On Mon, Jan 15, 2024 at 10:30 AM John wrote:</div>
        <div class="gmail_quote">
            <p>Quoted content</p>
        </div>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("My reply.") ?? false)
        XCTAssertFalse(result?.contains("John wrote:") ?? true)
        XCTAssertFalse(result?.contains("Quoted content") ?? true)
    }

    func testRemoveQuotes_gmailAttrWithMultipleClasses_removesAttribution() {
        let html = """
        <p>Thanks!</p>
        <div class="gmail_attr gmail_attr_default">On Jan 15, Jane wrote:</div>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("Thanks!") ?? false)
        XCTAssertFalse(result?.contains("Jane wrote:") ?? true)
    }

    // MARK: - Outlook Quote Patterns (Truncation-based)
    // These patterns use truncation rather than removal to handle nested divs correctly

    func testRemoveQuotes_outlookReferenceContainerById_truncatesAtQuote() {
        // This tests the fix for Steven Gambrel's email showing quoted text
        // Outlook uses id="mail-editor-reference-message-container"
        let html = """
        <p>Well, gee, thanks....</p>
        <div id="mail-editor-reference-message-container">
            <p>Previous conversation content</p>
        </div>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("Well, gee, thanks....") ?? false)
        XCTAssertFalse(result?.contains("Previous conversation content") ?? true)
    }

    func testRemoveQuotes_outlookReferenceContainerWithPrefix_truncatesAtQuote() {
        // Outlook sometimes adds prefixes like "x_" to IDs
        let html = """
        <p>Main content here.</p>
        <div id="x_mail-editor-reference-message-container">
            <p>Quoted reply chain</p>
        </div>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("Main content here.") ?? false)
        XCTAssertFalse(result?.contains("Quoted reply chain") ?? true)
    }

    func testRemoveQuotes_outlookReferenceContainerWithAttributes_truncatesAtQuote() {
        let html = """
        <p>Response.</p>
        <div class="some-class" id="mail-editor-reference-message-container" style="margin-top:20px">
            <p>Original email</p>
        </div>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("Response.") ?? false)
        XCTAssertFalse(result?.contains("Original email") ?? true)
    }

    func testRemoveQuotes_outlookWordSection_preservesMainContent() {
        // WordSection1 is Outlook's MAIN CONTENT container, not quoted content
        // It should NOT cause truncation
        let html = """
        <div class="WordSection1">
            <p>Well, gee, thanks....</p>
            <p>This is the actual email content that should be preserved.</p>
        </div>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("Well, gee, thanks....") ?? false)
        XCTAssertTrue(result?.contains("This is the actual email content") ?? false)
    }

    func testRemoveQuotes_outlookWordSectionWithQuotedContent_preservesMainTruncatesQuote() {
        // Real Outlook email structure: WordSection1 contains both main content AND quoted content
        // The quote is identified by mail-editor-reference-message-container, not WordSection
        let html = """
        <div class="WordSection1">
            <p>Well, gee, thanks....</p>
            <div id="mail-editor-reference-message-container">
                <div style="border-top:solid #B5C4DF 1.0pt">
                    <p><b>From:</b> Someone</p>
                </div>
                <p>This is quoted content that should be removed</p>
            </div>
        </div>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("Well, gee, thanks....") ?? false)
        XCTAssertFalse(result?.contains("This is quoted content") ?? true)
    }

    func testRemoveQuotes_outlookBlueBorderSeparator_preservesContent() {
        // Outlook blue border (#b5c4df) is used for layout throughout emails,
        // not just for quote boundaries. This was causing legitimate content truncation.
        // Quoted content should be detected via mail-editor-reference-message-container instead.
        let html = """
        <p>My response.</p>
        <div style="border-top:solid #B5C4DF 1.0pt;padding:3.0pt 0in 0in 0in">
            <p>From: John</p>
            <p>Additional content</p>
        </div>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("My response.") ?? false)
        // Blue border alone should NOT cause truncation
        XCTAssertTrue(result?.contains("Additional content") ?? false)
    }

    func testRemoveQuotes_outlookBlueBorderWithReferenceContainer_truncatesAtContainer() {
        // When blue border is inside a mail-editor-reference-message-container,
        // the container ID (not the border) should trigger truncation
        let html = """
        <p>Reply.</p>
        <div id="mail-editor-reference-message-container">
            <div style="border-top:solid #b5c4df 1pt">
                <p>Quoted</p>
            </div>
        </div>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("Reply.") ?? false)
        XCTAssertFalse(result?.contains("Quoted") ?? true)
    }

    func testRemoveQuotes_outlookMessageHeader_removesQuote() {
        let html = """
        <p>Got it, thanks.</p>
        <div class="OutlookMessageHeader">
            <p>From: sender@example.com</p>
        </div>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("Got it, thanks.") ?? false)
        XCTAssertFalse(result?.contains("sender@example.com") ?? true)
    }

    func testRemoveQuotes_outlookGrayDividerHeaderWithoutContainer_truncatesQuotedThread() {
        // Real-world Outlook structure: no mail-editor-reference-message-container ID.
        // Quoted thread starts after a gray top-border header with From/Sent/To/Cc/Subject.
        let html = """
        <div class="WordSection1">
            <p>I have a wake to attend tomorrow evening unfortunately</p>
            <div style="border:none;border-top:solid #E1E1E1 1.0pt;padding:3.0pt 0in 0in 0in">
                <p><b>From:</b> Dominic Cozzetto</p>
                <p><b>Sent:</b> Wednesday, February 11, 2026 12:18 PM</p>
                <p><b>To:</b> Flock, Kathleen; Rory Gildea</p>
                <p><b>Cc:</b> Brynn Putnam; Kevin Thau</p>
                <p><b>Subject:</b> BofA Intro &amp; Next Steps</p>
            </div>
            <p>Hello Kathy &amp; Rory,</p>
            <p>Kevin and Brynn would like to move forward with a call.</p>
        </div>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("I have a wake to attend tomorrow evening unfortunately") ?? false)
        XCTAssertFalse(result?.contains("Hello Kathy &amp; Rory,") ?? true)
        XCTAssertFalse(result?.contains("Kevin and Brynn would like to move forward with a call.") ?? true)
    }

    // MARK: - Blockquote Patterns

    func testRemoveQuotes_blockquote_removesQuote() {
        let html = """
        <p>My thoughts on this.</p>
        <blockquote>
            <p>Previous message content</p>
        </blockquote>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("My thoughts on this.") ?? false)
        XCTAssertFalse(result?.contains("Previous message content") ?? true)
    }

    func testRemoveQuotes_blockquoteWithAttributes_removesQuote() {
        let html = """
        <p>Response.</p>
        <blockquote type="cite" style="border-left:2px solid gray">
            <p>Cited content</p>
        </blockquote>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("Response.") ?? false)
        XCTAssertFalse(result?.contains("Cited content") ?? true)
    }

    // MARK: - Main Content Preservation

    func testRemoveQuotes_preservesMainContent() {
        let html = """
        <div>
            <p>First paragraph of response.</p>
            <p>Second paragraph with important info.</p>
            <p>Third paragraph concluding.</p>
        </div>
        <div class="gmail_quote">
            <p>Quoted text to remove</p>
        </div>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("First paragraph of response.") ?? false)
        XCTAssertTrue(result?.contains("Second paragraph with important info.") ?? false)
        XCTAssertTrue(result?.contains("Third paragraph concluding.") ?? false)
        XCTAssertFalse(result?.contains("Quoted text to remove") ?? true)
    }

    func testRemoveQuotes_preservesFormattingInMainContent() {
        let html = """
        <p>Here is my <strong>important</strong> response with <em>formatting</em>.</p>
        <div class="gmail_quote">
            <p>Quoted</p>
        </div>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("<strong>important</strong>") ?? false)
        XCTAssertTrue(result?.contains("<em>formatting</em>") ?? false)
    }

    // MARK: - Multiple Quote Blocks

    func testRemoveQuotes_multipleQuoteBlocks_removesAll() {
        let html = """
        <p>My response.</p>
        <div class="gmail_quote">
            <p>First quote</p>
        </div>
        <p>More content.</p>
        <blockquote>
            <p>Second quote</p>
        </blockquote>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("My response.") ?? false)
        XCTAssertTrue(result?.contains("More content.") ?? false)
        XCTAssertFalse(result?.contains("First quote") ?? true)
        XCTAssertFalse(result?.contains("Second quote") ?? true)
    }

    // MARK: - "On ... wrote:" Truncation Pattern

    func testRemoveQuotes_onWrotePattern_truncates() {
        let html = """
        <p>Sounds good!</p>
        <p>On Monday, January 15, 2024, John Doe wrote:</p>
        <p>Original message here</p>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("Sounds good!") ?? false)
        XCTAssertFalse(result?.contains("Original message here") ?? true)
    }

    // MARK: - Real-World Scenario Tests

    func testRemoveQuotes_stevenGambrelScenario_showsOnlyResponse() {
        // Simulates the Steven Gambrel email scenario
        let html = """
        <html>
        <body>
        <p>Well, gee, thanks....</p>
        <div id="mail-editor-reference-message-container">
            <div style="border-top:solid #B5C4DF 1.0pt">
                <p><b>From:</b> Brynn Putnam</p>
                <p><b>Subject:</b> Re: 1040 Fifth Ave - Proposed Artworks</p>
            </div>
            <div>
                <p>Previous email chain content here</p>
            </div>
        </div>
        </body>
        </html>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("Well, gee, thanks....") ?? false)
        XCTAssertFalse(result?.contains("Previous email chain content") ?? true)
    }

    func testRemoveQuotes_brynnPutnamScenario_showsFullResponse() {
        // Simulates the Brynn Putnam email scenario with gmail_quote gmail_quote_container
        let html = """
        <html>
        <body>
        <div dir="ltr">
            <p>Thank you for indulging us with the option to review.</p>
            <br>
            <p>It turns out the art that we have doesn't work for the space.</p>
        </div>
        <div class="gmail_quote gmail_quote_container">
            <div class="gmail_attr">On Wed, Jan 15, 2024 Steven wrote:</div>
            <blockquote>
                <p>Previous message about artworks</p>
            </blockquote>
        </div>
        </body>
        </html>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("Thank you for indulging us") ?? false)
        XCTAssertTrue(result?.contains("It turns out the art") ?? false)
        XCTAssertFalse(result?.contains("Previous message about artworks") ?? true)
    }

    // MARK: - Pattern Ordering Tests

    func testRemoveQuotes_onWroteInContentWithOutlookContainer_preservesContent() {
        // "On ... wrote:" in main content should NOT truncate when Outlook container exists
        // This tests the fix for Daisy Dixon's email being truncated prematurely
        let html = """
        <p>Hi Brynn and Kevin, I'm excited to be joining the project.</p>
        <p>On the furniture schemes, I wrote: we need to finalize selections.</p>
        <p>More important content here.</p>
        <div id="mail-editor-reference-message-container">
            <p>On Jan 15, 2024, Someone wrote:</p>
            <p>Quoted content</p>
        </div>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("I'm excited to be joining the project") ?? false)
        XCTAssertTrue(result?.contains("On the furniture schemes, I wrote:") ?? false)
        XCTAssertTrue(result?.contains("More important content here") ?? false)
        XCTAssertFalse(result?.contains("Quoted content") ?? true)
    }

    func testRemoveQuotes_onWrotePatternMatchesBeforeContainer_containerTakesPriority() {
        // Even if "On ... wrote:" would match earlier in the HTML, the Outlook container
        // should be found first because it's checked first in pattern order
        let html = """
        <p>Response text.</p>
        <p>On Monday, she wrote: some notes about the project.</p>
        <p>Additional important content.</p>
        <div id="x_mail-editor-reference-message-container">
            <p>Previous email chain</p>
        </div>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("Response text.") ?? false)
        XCTAssertTrue(result?.contains("On Monday, she wrote:") ?? false)
        XCTAssertTrue(result?.contains("Additional important content.") ?? false)
        XCTAssertFalse(result?.contains("Previous email chain") ?? true)
    }

    // MARK: - Mid-sentence "on the" preservation

    func testRemoveQuotes_onTheInMiddleOfSentence_preservesContent() {
        // Bug fix: "on the" in middle of sentence should NOT trigger "On ... wrote:" pattern
        let html = """
        <p>Hey!</p>
        <p>I need to reload on the Chablis. When can you deliver?</p>
        <p>Thanks!</p>
        <br>
        <p>On Jan 31, 2026 at 12:31 PM, Scott Wunderlich wrote:</p>
        <p>Hey Kevin, just checking in.</p>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("on the Chablis") ?? false, "Should preserve 'on the Chablis'")
        XCTAssertTrue(result?.contains("When can you deliver") ?? false)
        XCTAssertTrue(result?.contains("Thanks!") ?? false)
        XCTAssertFalse(result?.contains("Hey Kevin") ?? true, "Should remove quoted content")
    }

    func testRemoveQuotes_onInMiddleParagraph_preservesContent() {
        // "on" appearing mid-paragraph should be preserved
        let html = """
        <p>I'm working on the project and it's going well.</p>
        <br>
        <p>On Monday, January 15, 2024, John Doe wrote:</p>
        <p>Original message here</p>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("working on the project") ?? false)
        XCTAssertFalse(result?.contains("Original message here") ?? true)
    }

    // MARK: - Edge Cases

    func testRemoveQuotes_emptyQuoteBlock_removesEmptyBlock() {
        let html = """
        <p>Content.</p>
        <div class="gmail_quote"></div>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("Content.") ?? false)
        XCTAssertFalse(result?.contains("gmail_quote") ?? true)
    }

    func testRemoveQuotes_nestedQuotes_removesAll() {
        let html = """
        <p>Response.</p>
        <div class="gmail_quote">
            <p>First level quote</p>
            <blockquote>
                <p>Nested quote</p>
            </blockquote>
        </div>
        """
        let result = HTMLQuoteRemover.removeQuotes(from: html)
        XCTAssertTrue(result?.contains("Response.") ?? false)
        XCTAssertFalse(result?.contains("First level quote") ?? true)
        XCTAssertFalse(result?.contains("Nested quote") ?? true)
    }

    // MARK: - Removal Modes

    func testRemoveQuotes_quotedOnlyMode_preservesSignatureBlocks() {
        let html = """
        <p>Main content.</p>
        <div class="signature">Signature details</div>
        """

        let result = HTMLQuoteRemover.removeQuotes(from: html, mode: .quotedOnly)

        XCTAssertTrue(result?.contains("Main content.") ?? false)
        XCTAssertTrue(result?.contains("Signature details") ?? false)
    }

    func testRemoveQuotes_quotedAndSignaturesMode_removesSignatureBlocks() {
        let html = """
        <p>Main content.</p>
        <div class="signature">Signature details</div>
        """

        let result = HTMLQuoteRemover.removeQuotes(from: html, mode: .quotedAndSignatures)

        XCTAssertTrue(result?.contains("Main content.") ?? false)
        XCTAssertFalse(result?.contains("Signature details") ?? true)
    }
}
