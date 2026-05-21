import XCTest
@testable import esc_chatmail

final class HTMLMeaningfulContentCheckerTests: XCTestCase {
    func testHasMeaningfulContent_nestedHiddenPreheaderMarkupWithoutVisibleContent_returnsFalse() {
        let html = """
        <html>
        <head>
            <title>Inbox preview</title>
        </head>
        <body>
            <!-- Preview copy should not count as message content. -->
            <div class="preheader">
                <div class="preview-text">
                    <table class="m-hide">
                        <tr><td>Open now for a limited offer.</td></tr>
                    </table>
                </div>
            </div>
        </body>
        </html>
        """

        XCTAssertFalse(HTMLMeaningfulContentChecker.hasMeaningfulContent(html))
    }

    func testHasMeaningfulContent_visibleContentAfterHiddenBlocks_returnsTrue() {
        let html = """
        <div class="preheader">This is hidden preview copy.</div>
        <table style="display: none;">
            <tr><td>Hidden layout copy.</td></tr>
        </table>
        <p>Your receipt is ready.</p>
        """

        XCTAssertTrue(HTMLMeaningfulContentChecker.hasMeaningfulContent(html))
    }

    func testHasMeaningfulContent_imageOnlyTemplate_returnsTrue() {
        let html = """
        <table role="presentation">
            <tr>
                <td>
                    <img src="https://example.com/banner.png" alt="">
                </td>
            </tr>
        </table>
        """

        XCTAssertTrue(HTMLMeaningfulContentChecker.hasMeaningfulContent(html))
    }

    func testHasMeaningfulContent_deepNestedPreheaderTables_completesQuickly() {
        let depth = 600
        let openingTags = String(repeating: "<table class=\"preheader\"><tr><td>", count: depth)
        let closingTags = String(repeating: "</td></tr></table>", count: depth)
        let html = openingTags + "Hidden preview text" + closingTags

        let start = CFAbsoluteTimeGetCurrent()
        let result = HTMLMeaningfulContentChecker.hasMeaningfulContent(html)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertFalse(result)
        XCTAssertLessThan(elapsed, 1.0)
    }
}
