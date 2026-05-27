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

    func testAllFlagEnablesAllDOMProcessingPaths() {
        XCTAssertFalse(EmailDOMFeatureFlag.isQuoteRemovalEnabled())
        XCTAssertFalse(EmailDOMFeatureFlag.isTextExtractionEnabled())
        XCTAssertFalse(EmailDOMFeatureFlag.isInlineContentIDExtractionEnabled())
        XCTAssertFalse(EmailDOMFeatureFlag.isHTMLSanitizationEnabled())

        UserDefaults.standard.set(true, forKey: "EmailDOM_All")

        XCTAssertTrue(EmailDOMFeatureFlag.isQuoteRemovalEnabled())
        XCTAssertTrue(EmailDOMFeatureFlag.isTextExtractionEnabled())
        XCTAssertTrue(EmailDOMFeatureFlag.isInlineContentIDExtractionEnabled())
        XCTAssertTrue(EmailDOMFeatureFlag.isHTMLSanitizationEnabled())
    }

    func testAllFlagRoutesPublicQuoteRemovalThroughDOMPath() {
        UserDefaults.standard.set(true, forKey: "EmailDOM_All")
        let html = """
        <p>Current reply.</p>
        <div class="gmail_quote"><p>Quoted history should be hidden.</p></div>
        """

        let result = HTMLQuoteRemover.removeQuotes(from: html) ?? ""
        let visibleText = TextProcessing.extractPlainText(from: result)

        XCTAssertTrue(visibleText.contains("Current reply."))
        XCTAssertFalse(visibleText.contains("Quoted history should be hidden."))
    }

    func testAllFlagRoutesPlainTextExtractionThroughDOMPath() {
        UserDefaults.standard.set(true, forKey: "EmailDOM_All")
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

    func testAllFlagRoutesInlineContentIDExtractionThroughDOMPath() {
        UserDefaults.standard.set(true, forKey: "EmailDOM_All")
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

    private func clearDOMFlags() {
        UserDefaults.standard.removeObject(forKey: "EmailDOM_QuoteRemoval")
        UserDefaults.standard.removeObject(forKey: "EmailDOM_TextExtraction")
        UserDefaults.standard.removeObject(forKey: "EmailDOM_InlineContentIDExtraction")
        UserDefaults.standard.removeObject(forKey: "EmailDOM_HTMLSanitization")
        UserDefaults.standard.removeObject(forKey: "EmailDOM_All")
    }
}
