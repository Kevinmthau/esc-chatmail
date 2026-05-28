import XCTest
@testable import esc_chatmail

final class EmailDOMPublicPathTests: XCTestCase {
    func testPublicQuoteRemovalUsesDOMPath() {
        let html = """
        <p>Current reply.</p>
        <div class="gmail_quote"><p>Quoted history should be hidden.</p></div>
        """

        let result = HTMLQuoteRemover.removeQuotes(from: html) ?? ""
        let visibleText = TextProcessing.extractPlainText(from: result)

        XCTAssertTrue(visibleText.contains("Current reply."))
        XCTAssertFalse(visibleText.contains("Quoted history should be hidden."))
    }

    func testPublicPlainTextExtractionUsesDOMPath() {
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

    func testPublicPlainTextExtractionRecoversTruncatedOpeningTag() {
        let html = "<div style=\"font-family: Arial;\nVisible text"

        let text = TextProcessing.extractPlainText(from: html)

        XCTAssertEqual(text, "Visible text")
    }

    func testPublicPlainTextExtractionRecoversPartiallyParsedTruncatedOpeningTag() {
        let html = "Intro text <div style=\"font-family: Arial;\nVisible text"

        let text = TextProcessing.extractPlainText(from: html)

        XCTAssertEqual(text, "Intro text\nVisible text")
    }

    func testPublicPlainTextExtractionPreservesAngleBracketEmailAddress() {
        let text = "Contact <alice@example.com> for details"

        let extracted = TextProcessing.extractPlainText(from: text)

        XCTAssertEqual(extracted, text)
    }

    func testPublicInlineContentIDExtractionUsesDOMPath() {
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

    func testPublicHTMLSanitizerServiceUsesDOMFirstPass() {
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
}
