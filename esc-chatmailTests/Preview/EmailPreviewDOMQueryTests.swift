import XCTest
@testable import esc_chatmail

final class EmailPreviewDOMQueryTests: XCTestCase {
    func testHTMLSummary_extractsUnquotedPreheaderAndNestedActionText() throws {
        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>Fallback title</title></head>
        <body>
            <div class=preheader>Early access starts today</div>
            <a href=https://example.com/start><span>Get <strong>started</strong></span></a>
        </body>
        </html>
        """

        let summary = try XCTUnwrap(EmailPreviewDOMQuery(html: html)).htmlSummary()

        XCTAssertEqual(summary.titleText, "Fallback title")
        XCTAssertEqual(summary.preheaderText, "Early access starts today")
        XCTAssertEqual(summary.actionLinkTexts, ["Get started"])
    }

    func testImages_extractsAttributesAndFollowingTextUntilNextImage() throws {
        let html = """
        <!DOCTYPE html>
        <html>
        <body>
            <img src="https://cdn.example.com/header.jpg" width="238.68" height="auto" alt="Header">
            <p>Shop | Events | Wine Club</p>
            <img src="https://cdn.example.com/hero.jpg" width="640" height="320" alt="Lead story hero">
            <p>This is the story text that should belong to the hero image.</p>
        </body>
        </html>
        """

        let images = try XCTUnwrap(EmailPreviewDOMQuery(html: html)).images()

        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images[0].sourceURL, "https://cdn.example.com/header.jpg")
        XCTAssertEqual(images[0].width, 239)
        XCTAssertNil(images[0].height)
        XCTAssertEqual(images[0].followingText, "Shop | Events | Wine Club")
        XCTAssertEqual(images[1].sourceURL, "https://cdn.example.com/hero.jpg")
        XCTAssertTrue(images[1].followingText.contains("story text"))
    }
}
