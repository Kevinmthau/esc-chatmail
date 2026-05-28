import XCTest
@testable import esc_chatmail

final class EmailDOMFeatureFlagIntegrationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        clearDOMFlags()
    }

    override func tearDown() {
        clearDOMFlags()
        super.tearDown()
    }

    func testAbsentFlagsEnableAllDOMProcessingPaths() {
        assertAllDOMPathsEnabled()
    }

    func testAllFlagFalseDisablesAllDOMProcessingPaths() {
        UserDefaults.standard.set(true, forKey: "EmailDOM_QuoteRemoval")
        UserDefaults.standard.set(true, forKey: "EmailDOM_TextExtraction")
        UserDefaults.standard.set(true, forKey: "EmailDOM_InlineContentIDExtraction")
        UserDefaults.standard.set(true, forKey: "EmailDOM_HTMLSanitization")

        UserDefaults.standard.set(false, forKey: "EmailDOM_All")

        assertAllDOMPathsDisabled()
    }

    func testAllFlagTrueEnablesAllDOMProcessingPaths() {
        UserDefaults.standard.set(false, forKey: "EmailDOM_QuoteRemoval")
        UserDefaults.standard.set(false, forKey: "EmailDOM_TextExtraction")
        UserDefaults.standard.set(false, forKey: "EmailDOM_InlineContentIDExtraction")
        UserDefaults.standard.set(false, forKey: "EmailDOM_HTMLSanitization")

        UserDefaults.standard.set(true, forKey: "EmailDOM_All")

        assertAllDOMPathsEnabled()
    }

    func testComponentFalseDisablesOnlyThatPathWhenAllFlagAbsent() {
        UserDefaults.standard.set(false, forKey: "EmailDOM_QuoteRemoval")
        XCTAssertFalse(EmailDOMFeatureFlag.isQuoteRemovalEnabled())
        XCTAssertTrue(EmailDOMFeatureFlag.isTextExtractionEnabled())
        XCTAssertTrue(EmailDOMFeatureFlag.isInlineContentIDExtractionEnabled())
        XCTAssertTrue(EmailDOMFeatureFlag.isHTMLSanitizationEnabled())

        clearDOMFlags()
        UserDefaults.standard.set(false, forKey: "EmailDOM_TextExtraction")
        XCTAssertTrue(EmailDOMFeatureFlag.isQuoteRemovalEnabled())
        XCTAssertFalse(EmailDOMFeatureFlag.isTextExtractionEnabled())
        XCTAssertTrue(EmailDOMFeatureFlag.isInlineContentIDExtractionEnabled())
        XCTAssertTrue(EmailDOMFeatureFlag.isHTMLSanitizationEnabled())

        clearDOMFlags()
        UserDefaults.standard.set(false, forKey: "EmailDOM_InlineContentIDExtraction")
        XCTAssertTrue(EmailDOMFeatureFlag.isQuoteRemovalEnabled())
        XCTAssertTrue(EmailDOMFeatureFlag.isTextExtractionEnabled())
        XCTAssertFalse(EmailDOMFeatureFlag.isInlineContentIDExtractionEnabled())
        XCTAssertTrue(EmailDOMFeatureFlag.isHTMLSanitizationEnabled())

        clearDOMFlags()
        UserDefaults.standard.set(false, forKey: "EmailDOM_HTMLSanitization")
        XCTAssertTrue(EmailDOMFeatureFlag.isQuoteRemovalEnabled())
        XCTAssertTrue(EmailDOMFeatureFlag.isTextExtractionEnabled())
        XCTAssertTrue(EmailDOMFeatureFlag.isInlineContentIDExtractionEnabled())
        XCTAssertFalse(EmailDOMFeatureFlag.isHTMLSanitizationEnabled())
    }

    func testComponentTrueReEnablesThatPathWhenAllFlagAbsent() {
        UserDefaults.standard.set(false, forKey: "EmailDOM_QuoteRemoval")
        XCTAssertFalse(EmailDOMFeatureFlag.isQuoteRemovalEnabled())
        UserDefaults.standard.set(true, forKey: "EmailDOM_QuoteRemoval")
        XCTAssertTrue(EmailDOMFeatureFlag.isQuoteRemovalEnabled())

        UserDefaults.standard.set(false, forKey: "EmailDOM_TextExtraction")
        XCTAssertFalse(EmailDOMFeatureFlag.isTextExtractionEnabled())
        UserDefaults.standard.set(true, forKey: "EmailDOM_TextExtraction")
        XCTAssertTrue(EmailDOMFeatureFlag.isTextExtractionEnabled())

        UserDefaults.standard.set(false, forKey: "EmailDOM_InlineContentIDExtraction")
        XCTAssertFalse(EmailDOMFeatureFlag.isInlineContentIDExtractionEnabled())
        UserDefaults.standard.set(true, forKey: "EmailDOM_InlineContentIDExtraction")
        XCTAssertTrue(EmailDOMFeatureFlag.isInlineContentIDExtractionEnabled())

        UserDefaults.standard.set(false, forKey: "EmailDOM_HTMLSanitization")
        XCTAssertFalse(EmailDOMFeatureFlag.isHTMLSanitizationEnabled())
        UserDefaults.standard.set(true, forKey: "EmailDOM_HTMLSanitization")
        XCTAssertTrue(EmailDOMFeatureFlag.isHTMLSanitizationEnabled())
    }

    func testDefaultRoutesPublicQuoteRemovalThroughDOMPath() {
        let html = """
        <p>Current reply.</p>
        <div class="gmail_quote"><p>Quoted history should be hidden.</p></div>
        """

        let result = HTMLQuoteRemover.removeQuotes(from: html) ?? ""
        let visibleText = TextProcessing.extractPlainText(from: result)

        XCTAssertTrue(visibleText.contains("Current reply."))
        XCTAssertFalse(visibleText.contains("Quoted history should be hidden."))
    }

    func testDefaultRoutesPlainTextExtractionThroughDOMPath() {
        let html = """
        <div>First line<br>Second line</div>
        <script>alert('hidden')</script>
        <style>.hidden { display: none; }</style>
        """

        let text = TextProcessing.extractPlainText(from: html)

        XCTAssertTrue(text.contains("First line\nSecond line"))
        XCTAssertFalse(text.contains("alert"))
        XCTAssertFalse(text.contains("display: none"))
    }

    func testDefaultPlainTextExtractionFallsBackForTruncatedOpeningTag() {
        let html = "<div style=\"font-family: Arial;\nVisible text"

        let text = TextProcessing.extractPlainText(from: html)

        XCTAssertEqual(text, "Visible text")
    }

    func testDefaultPlainTextExtractionFallsBackForPartiallyParsedTruncatedOpeningTag() {
        let html = "Intro text <div style=\"font-family: Arial;\nVisible text"

        let text = TextProcessing.extractPlainText(from: html)

        XCTAssertEqual(text, "Intro text\nVisible text")
    }

    func testDefaultPlainTextExtractionPreservesAngleBracketEmailAddress() {
        let text = "Contact <alice@example.com> for details"

        let extracted = TextProcessing.extractPlainText(from: text)

        XCTAssertEqual(extracted, text)
    }

    func testDefaultRoutesInlineContentIDExtractionThroughDOMPath() {
        let html = """
        <html>
        <body>
          <img src="CID:&lt;Hero-Image&gt;">
          <table background="cid:bg-image.png"><tr><td>Cell</td></tr></table>
          <a href="https://example.com">External link</a>
        </body>
        </html>
        """

        let analysis = MessageBubbleHTMLAnalysisBuilder.build(
            canonicalHTML: html,
            hasHTMLSourceHint: true,
            isForwardedEmail: false,
            isLikelyCalendarInvite: false,
            bodyText: nil,
            cleanedSnippet: nil,
            senderName: nil,
            senderEmail: nil,
            subject: nil,
            attachmentSnapshots: []
        )

        XCTAssertEqual(
            analysis.referencedInlineContentIDs,
            ["hero-image", "bg-image.png"]
        )
    }

    func testDefaultRoutesHTMLSanitizationThroughDOMPath() {
        let html = #"""
        <body class="promo" style="margin:0" bgcolor="#f4f4f4" onload="steal()">
          <p>Offer</p>
          <script>alert('xss')</script>
        </body>
        """#

        let result = HTMLSanitizerService.shared.sanitize(
            html,
            rewriteModernImageFormatHints: false
        )
        let lowercasedResult = result.lowercased()

        XCTAssertTrue(lowercasedResult.contains("<html"))
        XCTAssertTrue(lowercasedResult.contains("<body"))
        XCTAssertTrue(result.contains(#"class="promo""#))
        XCTAssertTrue(result.contains(#"style="margin:0""#))
        XCTAssertTrue(result.contains("bgcolor=\"#f4f4f4\""))
        XCTAssertTrue(result.contains("<p>Offer</p>"))
        XCTAssertFalse(lowercasedResult.contains("onload"))
        XCTAssertFalse(lowercasedResult.contains("<script"))
        XCTAssertFalse(result.contains("alert('xss')"))
    }

    private func assertAllDOMPathsEnabled(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(EmailDOMFeatureFlag.isQuoteRemovalEnabled(), file: file, line: line)
        XCTAssertTrue(EmailDOMFeatureFlag.isTextExtractionEnabled(), file: file, line: line)
        XCTAssertTrue(
            EmailDOMFeatureFlag.isInlineContentIDExtractionEnabled(),
            file: file,
            line: line
        )
        XCTAssertTrue(EmailDOMFeatureFlag.isHTMLSanitizationEnabled(), file: file, line: line)
    }

    private func assertAllDOMPathsDisabled(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(EmailDOMFeatureFlag.isQuoteRemovalEnabled(), file: file, line: line)
        XCTAssertFalse(EmailDOMFeatureFlag.isTextExtractionEnabled(), file: file, line: line)
        XCTAssertFalse(
            EmailDOMFeatureFlag.isInlineContentIDExtractionEnabled(),
            file: file,
            line: line
        )
        XCTAssertFalse(EmailDOMFeatureFlag.isHTMLSanitizationEnabled(), file: file, line: line)
    }

    private func clearDOMFlags() {
        UserDefaults.standard.removeObject(forKey: "EmailDOM_QuoteRemoval")
        UserDefaults.standard.removeObject(forKey: "EmailDOM_TextExtraction")
        UserDefaults.standard.removeObject(forKey: "EmailDOM_InlineContentIDExtraction")
        UserDefaults.standard.removeObject(forKey: "EmailDOM_HTMLSanitization")
        UserDefaults.standard.removeObject(forKey: "EmailDOM_All")
    }
}
